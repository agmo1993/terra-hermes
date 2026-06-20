# lambda_email_processor.py
# Place in repo root. Build zip: zip lambda_email_processor.zip lambda_email_processor.py
import json
import boto3
import email
import os
import hmac
import hashlib
import urllib.request
from urllib.parse import unquote_plus
from datetime import datetime, timezone, timedelta

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['EMAIL_TABLE'])
ses = boto3.client('ses', region_name=os.environ.get('AWS_REGION', 'us-east-1'))

HERMES_WEBHOOK_URL = os.environ.get('HERMES_WEBHOOK_URL', '')
HERMES_WEBHOOK_SECRET = os.environ.get('HERMES_WEBHOOK_SECRET', '')
SEND_FROM = os.environ.get('SES_SEND_FROM', '')

def verify_signature(payload: bytes, signature: str) -> bool:
    if not HERMES_WEBHOOK_SECRET:
        return True
    expected = hmac.new(HERMES_WEBHOOK_SECRET.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)

def call_hermes_webhook(payload: dict) -> dict:
    """Forward parsed email to Hermes HTTP webhook."""
    if not HERMES_WEBHOOK_URL:
        return {'status': 'skipped', 'reason': 'no webhook URL configured'}

    data = json.dumps(payload).encode()
    headers = {
        'Content-Type': 'application/json',
        'X-Hermes-Signature': hmac.new(
            HERMES_WEBHOOK_SECRET.encode(), data, hashlib.sha256
        ).hexdigest() if HERMES_WEBHOOK_SECRET else ''
    }
    req = urllib.request.Request(HERMES_WEBHOOK_URL, data=data, headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {'status': 'error', 'http_status': e.code, 'body': e.read().decode()}
    except Exception as e:
        return {'status': 'error', 'error': str(e)}

def parse_email(raw_bytes: bytes) -> dict:
    """Parse raw .eml into structured dict."""
    msg = email.message_from_bytes(raw_bytes)

    parsed = {
        'message_id': msg.get('Message-ID', '').strip('<>'),
        'from': msg.get('From', ''),
        'to': msg.get('To', ''),
        'cc': msg.get('Cc', ''),
        'subject': msg.get('Subject', ''),
        'date': msg.get('Date', ''),
        'in_reply_to': msg.get('In-Reply-To', ''),
        'references': msg.get('References', ''),
        'text_body': '',
        'html_body': '',
        'attachments': []
    }

    for part in msg.walk():
        ctype = part.get_content_type()
        disp = part.get_content_disposition()
        payload = part.get_payload(decode=True) or b''

        if ctype == 'text/plain' and disp != 'attachment':
            parsed['text_body'] = payload.decode(errors='ignore')
        elif ctype == 'text/html' and disp != 'attachment':
            parsed['html_body'] = payload.decode(errors='ignore')
        elif part.get_filename():
            parsed['attachments'].append({
                'filename': part.get_filename(),
                'content_type': ctype,
                'size': len(payload),
                'content_id': part.get('Content-ID', '').strip('<>')
            })

    return parsed

def handler(event, context):
    results = []

    for record in event.get('Records', []):
        if 'Sns' not in record:
            continue

        ses_msg = json.loads(record['Sns']['Message'])
        receipt = ses_msg.get('receipt', {})
        mail = ses_msg.get('mail', {})
        message_id = mail.get('messageId', '')

        action = receipt.get('action', {})
        bucket = action.get('bucketName')
        key = unquote_plus(action.get('objectKey', ''))

        if not bucket or not key:
            results.append({'message_id': message_id, 'status': 'no_s3_action'})
            continue

        # Fetch raw email from S3
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            raw_email = obj['Body'].read()
        except Exception as e:
            results.append({'message_id': message_id, 'status': 's3_error', 'error': str(e)})
            continue

        # Parse
        parsed = parse_email(raw_email)
        parsed['message_id'] = message_id
        parsed['received_at'] = receipt.get('timestamp', datetime.now(timezone.utc).isoformat())
        parsed['spam_verdict'] = receipt.get('spamVerdict', {}).get('status', 'UNKNOWN')
        parsed['virus_verdict'] = receipt.get('virusVerdict', {}).get('status', 'UNKNOWN')
        parsed['spf_verdict'] = receipt.get('spfVerdict', {}).get('status', 'UNKNOWN')
        parsed['dkim_verdict'] = receipt.get('dkimVerdict', {}).get('status', 'UNKNOWN')

        # Store in DynamoDB
        item = {
            'message_id': message_id,
            'received_at': parsed['received_at'],
            'from_addr': parsed['from'],
            'to_addr': parsed['to'],
            'subject': parsed['subject'],
            'status': 'RECEIVED',
            'expires_at': int((datetime.now(timezone.utc) + timedelta(days=90)).timestamp())
        }
        table.put_item(Item=item)

        # Forward to Hermes
        webhook_payload = {
            'type': 'email_received',
            'email': parsed,
            'source': 'ses',
            'receipt': {
                'spam': parsed['spam_verdict'],
                'virus': parsed['virus_verdict'],
                'spf': parsed['spf_verdict'],
                'dkim': parsed['dkim_verdict']
            }
        }
        webhook_result = call_hermes_webhook(webhook_payload)

        # Update status
        table.update_item(
            Key={'message_id': message_id},
            UpdateExpression='SET #s = :s, webhook_result = :w',
            ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={':s': 'PROCESSED', ':w': webhook_result}
        )

        results.append({
            'message_id': message_id,
            'status': 'processed',
            'webhook': webhook_result
        })

    return {'statusCode': 200, 'body': json.dumps({'results': results})}

# Also export a send_email function for Hermes to use
def send_email(to_addresses: list, subject: str, body_text: str, body_html: str = None, reply_to: str = None) -> dict:
    """Send email via SES. Can be called by Hermes agent."""
    params = {
        'Source': SEND_FROM,
        'Destination': {'ToAddresses': to_addresses},
        'Message': {
            'Subject': {'Data': subject, 'Charset': 'UTF-8'},
            'Body': {'Text': {'Data': body_text, 'Charset': 'UTF-8'}}
        }
    }
    if body_html:
        params['Message']['Body']['Html'] = {'Data': body_html, 'Charset': 'UTF-8'}
    if reply_to:
        params['ReplyToAddresses'] = [reply_to]
    return ses.send_email(**params)
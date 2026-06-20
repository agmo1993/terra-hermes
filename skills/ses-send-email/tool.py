# ~/.hermes/skills/ses-send-email/tool.py
# Hermes tool: Send email via AWS SES
import os
import boto3

# Initialize SES client (uses instance IAM role)
ses = boto3.client('ses', region_name=os.environ.get('AWS_REGION', 'us-east-1'))
SEND_FROM = os.environ.get('SES_SEND_FROM', 'Hermes <noreply@yourdomain.com>')

def send_email(to: str, subject: str, body: str, html: str = None, reply_to: str = None) -> dict:
    """
    Send an email via AWS SES.

    Args:
        to: Recipient email address
        subject: Email subject
        body: Plain text body
        html: Optional HTML body
        reply_to: Optional reply-to address

    Returns:
        Dict with 'message_id' on success, or 'error' on failure
    """
    params = {
        'Source': SEND_FROM,
        'Destination': {'ToAddresses': [to]},
        'Message': {
            'Subject': {'Data': subject, 'Charset': 'UTF-8'},
            'Body': {'Text': {'Data': body, 'Charset': 'UTF-8'}}
        }
    }
    if html:
        params['Message']['Body']['Html'] = {'Data': html, 'Charset': 'UTF-8'}
    if reply_to:
        params['ReplyToAddresses'] = [reply_to]

    try:
        response = ses.send_email(**params)
        return {'success': True, 'message_id': response['MessageId']}
    except Exception as e:
        return {'success': False, 'error': str(e)}

# Register as Hermes tool
TOOLS = {
    'send_email': send_email
}
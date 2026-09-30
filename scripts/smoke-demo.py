#!/usr/bin/env python3
"""Black-box acceptance smoke. Refuses non-demo servers; NEVER sends real mail."""
import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

p = argparse.ArgumentParser()
p.add_argument('--url', default='http://127.0.0.1:8080')
p.add_argument('--output', default='test-results/smoke-demo.json')
a = p.parse_args()
base = a.url.rstrip('/') + '/api/v1'
token = None
checks = []

def request(method, path, data=None, expected=200, headers=None, raw=False):
    h = {'Accept': 'application/json'}
    if token:
        h['Authorization'] = 'Bearer ' + token
    if data is not None and not isinstance(data, bytes):
        data = json.dumps(data).encode()
        h['Content-Type'] = 'application/json'
    h.update(headers or {})
    r = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=20) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    assert status == expected, f'{method} {path}: expected {expected}, got {status}: {body[:300]!r}'
    return body if raw else (json.loads(body) if body else None)

def passed(name):
    checks.append({'name': name, 'status': 'passed'})
    print('PASS', name, flush=True)

try:
    health = request('GET', '/health')
    assert health.get('demoMode') is True, 'Refusing non-demo server: real mail MUST NOT be touched.'
    passed('explicit synthetic demo gate')
    request('GET', '/accounts', expected=401)
    request('POST', '/auth/login', {'username':'demo','password':'wrong-password'}, expected=401)
    passed('authentication required and invalid password rejected')
    login = request('POST', '/auth/login', {
        'username':os.getenv('MAIL_TEST_USERNAME','demo'),
        'password':os.getenv('MAIL_TEST_PASSWORD','demo-local-only')})
    assert login['demoMode'] is True
    token = login['accessToken']
    accounts = request('GET', '/accounts')['items']
    assert accounts
    account_id = accounts[0]['id']
    passed('login and account list')
    capabilities = request('GET', '/settings/capabilities')
    assert capabilities['demoMode'] is True
    request('GET', '/accounts/' + account_id + '/folders')
    messages = request('GET', '/messages?limit=2&folder=INBOX')
    assert messages['items']
    first = messages['items'][0]
    detail = request('GET', '/messages/' + first['id'])
    detail2 = request('GET', '/messages/' + first['id'])
    assert detail['isRead'] == detail2['isRead'], 'Reading body implicitly modified unread state'
    assert isinstance(detail['bodyText'], str)
    passed('mail list folders and non-mutating safe detail')
    if messages.get('nextCursor'):
        page2 = request('GET', '/messages?limit=2&folder=INBOX&cursor=' + urllib.parse.quote(messages['nextCursor']))
        assert not ({x['id'] for x in messages['items']} & {x['id'] for x in page2['items']})
        passed('stable pagination without duplicate rows')
    command_body = {'type':'SET_READ','messageId':first['id'], 'baseRevision':detail2['revision'],'value':True}
    key = 'smoke-command-' + uuid.uuid4().hex
    command = request('POST', '/commands', command_body, 202, {'Idempotency-Key':key})
    repeat = request('POST', '/commands', command_body, 202, {'Idempotency-Key':key})
    assert command['id'] == repeat['id']
    request('POST','/commands',{**command_body,'value':False},409,{'Idempotency-Key':key})
    for _ in range(30):
        result = request('GET','/commands/' + command['id'])
        if result['status'] in ('APPLIED','COMPLETED','SUCCEEDED','FAILED','UNKNOWN'): break
        time.sleep(.3)
    assert result['status'] in ('APPLIED','COMPLETED','SUCCEEDED'), result
    assert request('GET','/messages/' + first['id'])['isRead'] is True
    passed('durable mutation and idempotency conflict detection')
    subject = 'Synthetic smoke ' + uuid.uuid4().hex[:10]
    draft_data = {'accountId':account_id,'to':[{'address':'recipient@example.invalid','name':'Synthetic recipient'}], 'subject':subject,'bodyText':'中文与 Unicode ✓\nOnly local demo delivery.'}
    draft = request('POST','/drafts',draft_data,200)
    saved = request('PATCH','/drafts/' + draft['id'],{**draft_data,'revision':draft['revision'],'bodyText':'Updated synthetic draft'},200)
    request('PATCH','/drafts/' + draft['id'],{**draft_data,'revision':draft['revision']},409)
    passed('draft durable save and stale revision rejection')
    send_key = 'smoke-send-' + uuid.uuid4().hex
    intent = request('POST','/drafts/' + draft['id'] + '/send',{'revision':saved['revision']},202,{'Idempotency-Key':send_key})
    again = request('POST','/drafts/' + draft['id'] + '/send',{'revision':saved['revision']},202,{'Idempotency-Key':send_key})
    assert intent['id'] == again['id']
    for _ in range(40):
        state = request('GET','/send-intents/' + intent['id'])
        if state['status'] in ('ACCEPTED','SENT_COPY_CONFIRMED','FAILED','UNKNOWN'): break
        time.sleep(.3)
    assert state['status'] in ('ACCEPTED','SENT_COPY_CONFIRMED'), state
    all_intents = request('GET','/send-intents')['items']
    assert len([x for x in all_intents if x['id']==intent['id']]) == 1
    passed('synthetic send queue and duplicate submission suppression')
    request('GET','/changes')
    request('POST','/auth/logout',expected=204)
    request('GET','/accounts',expected=401)
    passed('change feed and token revocation')
except Exception as e:
    checks.append({'name':'execution','status':'failed','error':str(e)})
    raise
finally:
    os.makedirs(os.path.dirname(a.output) or '.',exist_ok=True)
    with open(a.output,'w',encoding='utf-8') as f:
        json.dump({'base':a.url,'syntheticOnly':True,'checks':checks},f,ensure_ascii=False,indent=2)

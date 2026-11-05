#!/usr/bin/python3
import json
import os
import select
import sys
import time

active = None
finish_at = None
aborted_at = None
reply_at = None
abort_command = None
wedged_abort = None
buffer = b''
session_file = os.environ['F_QUEUE_TEST_LOG'] + '.' + str(os.getpid()) + '.session'

def emit(value):
    print(json.dumps(value), flush=True)

def reply(command, data=None):
    emit(dict(type='response', id=command['id'], success=True, data=data or {}))

def settle(aborted=False, error=False):
    failures = {'ERROR_OFFLINE': 'Network connection lost (NSURLErrorNotConnectedToInternet)',
                'ERROR_QUOTA': '429 insufficient_quota: token balance exhausted',
                'ERROR_CONTEXT': 'context_length_exceeded: maximum context tokens reached',
                'ERROR_EXPIRED_TOKEN': '401 authentication token expired',
                'ERROR_RATE_LIMIT': '429 rate_limit_exceeded',
                'ERROR_OUTPUT_LIMIT': 'max_tokens: output token budget exhausted'}
    emit(dict(type='message_end', message=dict(role='assistant', stopReason='error' if error else 'aborted' if aborted else 'stop',
                                             errorMessage=failures.get(active, 'Mock model failure') if error else '', content=[dict(type='text', text='OK')])))
    emit(dict(type='agent_settled'))

while True:
    ready, _, _ = select.select([sys.stdin], [], [], .01)
    if ready:
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            break
        buffer += chunk
    while b'\n' in buffer:
        line, buffer = buffer.split(b'\n', 1)
        command = json.loads(line)
        with open(os.environ['F_QUEUE_TEST_LOG'], 'a') as stream:
            stream.write(json.dumps(dict(command, pid=os.getpid(), project=os.getcwd(), board=os.environ.get('F_BOARD_DIR'))) + '\n')
        kind = command['type']
        if kind == 'get_state':
            reply(command, dict(model=dict(provider='test', id='test-model', name='Test Model', reasoning=True), thinkingLevel='high', sessionFile=session_file))
        elif kind == 'get_available_models':
            reply(command, dict(models=[dict(provider='test', id='test-model', name='Test Model', reasoning=True)]))
        elif kind == 'get_available_thinking_levels':
            reply(command, dict(levels=['off', 'high']))
        elif kind == 'prompt':
            active = command['message']
            reply(command, dict(disposition='started'))
            finish_at = time.monotonic() + (20 if 'HOLD' in active else .16)
            emit(dict(type='message_start', message=dict(role='assistant')))
        elif kind == 'switch_session':
            session_file = command['sessionPath']
            reply(command)
        elif kind == 'set_model':
            emit(dict(type='thinking_level_changed', level='high'))
            if command.get('modelId') == 'reject-model':
                emit(dict(type='response', id=command['id'], success=False, error='Mock model unavailable'))
            else:
                reply(command)
        elif kind == 'set_thinking_level' and command.get('level') == 'reject-thinking':
            emit(dict(type='response', id=command['id'], success=False, error='Mock thinking unavailable'))
        elif kind == 'finish':
            reply(command)
            settle()
            active = None
            finish_at = None
        elif kind == 'fail_abort_late':
            if wedged_abort:
                emit(dict(type='response', id=wedged_abort['id'], success=False, error='Mock late abort failure'))
                wedged_abort = None
            reply(command)
        elif kind == 'abort':
            if active and 'WEDGE' in active:
                wedged_abort = command
                continue
            finish_at = None
            if active and 'ACK_FIRST' in active:
                reply(command)
                aborted_at = time.monotonic() + .08
            else:
                settle(aborted=True)
                active = None
                abort_command = command
                reply_at = time.monotonic() + .08
        else:
            reply(command)
    now = time.monotonic()
    if finish_at and now >= finish_at:
        settle(error=(active or '').startswith('ERROR_'))
        finish_at = None
        active = None
    if aborted_at and now >= aborted_at:
        settle(aborted=True)
        aborted_at = None
        active = None
    if reply_at and now >= reply_at:
        reply(abort_command)
        reply_at = None

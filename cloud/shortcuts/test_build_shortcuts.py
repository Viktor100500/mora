import unittest
import hashlib
import plistlib
import re
from build_shortcuts import workflow, wallet_delay, wallet_delay_diagnostic

CONFIG = {'projectURL': 'https://example.supabase.co', 'publicKey': 'sb_publishable_example'}

class WorkflowTests(unittest.TestCase):
    def test_production_templates_are_quiet_and_do_not_delay_capture(self):
        for wallet in (False, True):
            actions = workflow(CONFIG, wallet=wallet)['WFWorkflowActions']
            kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
            self.assertNotIn('notification', kinds)
            self.assertNotIn('delay', kinds)
            self.assertNotIn('showresult', kinds)
            self.assertEqual(kinds.count('downloadurl'), 1)
            if wallet:
                self.assertEqual(kinds[2:4], ['gettext', 'gettext'])

    def test_diagnostic_marks_start_before_wallet_extraction_and_reports_response_without_modal(self):
        actions = workflow(CONFIG, wallet=True, diagnostics=True)['WFWorkflowActions']
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
        self.assertNotIn('showresult', kinds)
        notes = [i for i, kind in enumerate(kinds) if kind == 'notification']
        self.assertEqual(len(notes), 4)  # start, response, and two mutually exclusive skip branches
        self.assertLess(notes[0], 3)  # before Amount / Merchant can throw
        self.assertLess(kinds.index('downloadurl'), notes[1])
        body = actions[notes[1]]['WFWorkflowActionParameters']['WFNotificationActionBody']
        response = actions[kinds.index('downloadurl')]['WFWorkflowActionParameters']['UUID']
        self.assertEqual(next(iter(body['Value']['attachmentsByRange'].values()))['OutputUUID'], response)

    def test_dictionary_sender_passes_card_without_merchant_specific_rules(self):
        actions = workflow(CONFIG, wallet=False)['WFWorkflowActions']
        card = next(a for a in actions if a['WFWorkflowActionParameters'].get('WFDictionaryKey') == 'card')
        post = next(a for a in actions if a['WFWorkflowActionIdentifier'].endswith('.downloadurl'))
        items = {i['WFKey']['Value']['string']: i['WFValue']['Value'] for i in
                 post['WFWorkflowActionParameters']['WFJSONValues']['Value']['WFDictionaryFieldValueItems']}
        self.assertEqual(set(items), {'p_token', 'p_event_id', 'p_amount', 'p_currency', 'p_merchant', 'p_occurred_at', 'p_card'})
        self.assertEqual(next(iter(items['p_card']['attachmentsByRange'].values()))['OutputUUID'],
                         card['WFWorkflowActionParameters']['UUID'])
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
        self.assertEqual(kinds.count('replace'), 3)  # event UUID and two whitespace guards
        wallet = workflow(CONFIG, wallet=True)['WFWorkflowActions']
        card_read = next(a for a in wallet if a['WFWorkflowActionParameters'].get('UUID') and 'Card or Pass' in str(a))
        wallet_post = next(a for a in wallet if a['WFWorkflowActionIdentifier'].endswith('.downloadurl'))
        wallet_items = {i['WFKey']['Value']['string']: i['WFValue']['Value'] for i in
                        wallet_post['WFWorkflowActionParameters']['WFJSONValues']['Value']['WFDictionaryFieldValueItems']}
        self.assertEqual(next(iter(wallet_items['p_card']['attachmentsByRange'].values()))['OutputUUID'],
                         card_read['WFWorkflowActionParameters']['UUID'])

    def test_preview_has_no_network_or_notifications(self):
        actions = workflow(CONFIG, preview=True, diagnostics=True)['WFWorkflowActions']
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
        self.assertNotIn('downloadurl', kinds)
        self.assertNotIn('notification', kinds)
        self.assertEqual(kinds.count('dictionary'), 1)

    def test_templates_do_not_infer_wallet_currency_or_embed_phone_credentials(self):
        for wallet in (False, True):
            with self.subTest(wallet=wallet):
                result = workflow(CONFIG, wallet=wallet, diagnostics=True)
                actions = result['WFWorkflowActions']
                self.assertEqual(actions[1]['WFWorkflowActionParameters']['WFTextActionText'], '0' * 64)
                self.assertEqual(result['WFWorkflowImportQuestions'][0]['ActionIndex'], 1)
                if wallet:
                    self.assertEqual(actions[5]['WFWorkflowActionParameters']['WFTextActionText'], '')
                else:
                    keys = [a['WFWorkflowActionParameters']['WFDictionaryKey'] for a in actions
                            if a['WFWorkflowActionIdentifier'].endswith('.getvalueforkey')]
                    self.assertEqual(keys, ['amount', 'merchant', 'currency', 'card'])


class DiagnosticRunner:
    """Evaluate the generated data/control flow with two staged Wallet snapshots.

    This model exercises incomplete/changed inputs without a live financial POST.
    It does not verify the Apple runtime or the availability of Wallet properties.
    """
    def __init__(self, before, after):
        self.snapshots = [before, after]
        self.phase = 0
        self.outputs = {}
        self.requests = []
        self.notifications = []
        self.date_reads = 0
        self.delays = []

    def resolve(self, value):
        if not isinstance(value, dict):
            return str(value)
        if value.get('WFSerializationType') == 'WFTextTokenAttachment':
            return self.resolve(value['Value'])
        if value.get('WFSerializationType') == 'WFTextTokenString':
            body = value['Value']
            attachments = {int(re.match(r'\{(\d+),', k)[1]): v
                           for k, v in body.get('attachmentsByRange', {}).items()}
            result, position = '', 0
            for c in body['string']:
                result += self.resolve(attachments[position]) if c == '\ufffc' else c
                position += len(c.encode('utf-16-le')) // 2
            return result
        if value.get('Type') == 'Variable':
            return self.resolve(value['Variable'])
        if value.get('Type') == 'ActionOutput':
            return self.outputs[value['OutputUUID']]
        if value.get('Type') == 'CurrentDate':
            return '2026-10-24T12:00:00Z'
        if value.get('Type') == 'ExtensionInput':
            if not value.get('Aggrandizements'):
                return self.snapshots[self.phase]
            property_name = value['Aggrandizements'][0]['PropertyName']
            return self.snapshots[self.phase].get(property_name, '')
        raise AssertionError(f'Unsupported binding: {value}')

    def fields(self, value):
        return {self.resolve(v['WFKey']): self.resolve(v['WFValue'])
                for v in value['Value']['WFDictionaryFieldValueItems']}

    def run(self, actions):
        last = ''
        i = 0
        while i < len(actions):
            item = actions[i]
            kind = item['WFWorkflowActionIdentifier'].removeprefix('is.workflow.actions.')
            p = item['WFWorkflowActionParameters']
            if kind == 'conditional':
                self.assert_start(p)
                group = p['GroupingIdentifier']
                otherwise = next(j for j in range(i + 1, len(actions))
                                 if actions[j]['WFWorkflowActionParameters'].get('GroupingIdentifier') == group
                                 and actions[j]['WFWorkflowActionParameters']['WFControlFlowMode'] == 1)
                end = next(j for j in range(otherwise + 1, len(actions))
                           if actions[j]['WFWorkflowActionParameters'].get('GroupingIdentifier') == group
                           and actions[j]['WFWorkflowActionParameters']['WFControlFlowMode'] == 2)
                value = self.resolve(p['WFInput'])
                if p['WFCondition'] == 100:
                    condition = bool(value)
                else:
                    assert p['WFCondition'] == 4
                    condition = value == self.resolve(p['WFConditionalActionString'])
                last = self.run(actions[i + 1:otherwise] if condition else actions[otherwise + 1:end])
                self.outputs[actions[end]['WFWorkflowActionParameters']['UUID']] = last
                i = end + 1
                continue
            if kind == 'gettext': last = self.resolve(p['WFTextActionText'])
            elif kind == 'getvalueforkey': last = self.resolve(p['WFInput']).get(p['WFDictionaryKey'], '')
            elif kind == 'format.date':
                self.date_reads += 1
                last = self.resolve(p['WFDate'])
            elif kind == 'number.random': last = '123456789'
            elif kind == 'hash': last = hashlib.sha256(self.resolve(p['WFInput']).encode()).hexdigest()
            elif kind == 'text.replace':
                # Shortcuts uses ICU's $1 syntax, unlike Python's replacement syntax.
                replacement = re.sub(r'\$(\d)', r'\\g<\1>', p['WFReplaceTextReplace'])
                last = re.sub(p['WFReplaceTextFind'], replacement, self.resolve(p['WFInput']))
            elif kind == 'delay':
                self.delays.append(p['WFDelayTime'])
                self.phase = 1
            elif kind == 'notification': self.notifications.append(self.resolve(p['WFNotificationActionBody']))
            elif kind == 'dictionary': last = self.fields(p['WFItems'])
            elif kind == 'downloadurl':
                self.requests.append(self.fields(p['WFJSONValues']))
                last = '{"state":"pending"}'
            elif kind != 'comment': raise AssertionError(f'Unsupported action: {kind}')
            self.outputs[p['UUID']] = last
            i += 1
        return last

    @staticmethod
    def assert_start(parameters):
        assert parameters['WFControlFlowMode'] == 0


class WalletDelayDiagnosticTests(unittest.TestCase):
    def test_staged_inputs_keep_one_request_and_preserve_available_fields(self):
        cases = [
            (('', ''), ('$3.25', 'PATH'), ('$3.25', 'PATH'), 'Поля изменились'),
            (('$3.25', 'PATH'), ('', ''), ('$3.25', 'PATH'), 'Поля изменились'),
            (('$3.25', ''), ('', 'PATH'), ('$3.25', 'PATH'), 'Поля изменились'),
            (('$3.25', 'PATH'), ('$3.25', 'PATH'), ('$3.25', 'PATH'), 'Без изменений'),
            (('$1', 'PATH'), ('$3.25', 'PATH'), ('$3.25', 'PATH'), 'Поля изменились'),
        ]
        for before, after, expected, comparison in cases:
            with self.subTest(before=before, after=after):
                w = plistlib.loads(plistlib.dumps(wallet_delay_diagnostic(CONFIG), fmt=plistlib.FMT_BINARY))
                runner = DiagnosticRunner(dict(zip(('Amount', 'Merchant'), before)),
                                          dict(zip(('Amount', 'Merchant'), after)))
                runner.run(w['WFWorkflowActions'])
                self.assertEqual(len(runner.requests), 1)
                request = runner.requests[0]
                self.assertEqual((request['p_amount'], request['p_merchant']), expected)
                self.assertEqual(request['p_currency'], '')
                self.assertEqual(runner.date_reads, 1)
                self.assertEqual(runner.delays, [5])
                self.assertRegex(request['p_event_id'], r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$')
                self.assertEqual(len(runner.notifications), 3)
                self.assertTrue(all(request['p_event_id'] in note for note in runner.notifications))
                self.assertIn(comparison, runner.notifications[1])

    def test_missing_fields_after_wait_never_send_a_request_or_claim_delivery(self):
        for before, after in [(('', ''), ('', '')), (('', ''), ('$2.99', '')),
                              (('', ''), ('', 'Walgreens')), (('$2.99', ''), ('', '')),
                              (('', ''), (' \n\t', 'Walgreens')),
                              (('', ''), ('$2.99', '\u00a0\u202f'))]:
            with self.subTest(before=before, after=after):
                w = plistlib.loads(plistlib.dumps(wallet_delay_diagnostic(CONFIG), fmt=plistlib.FMT_BINARY))
                runner = DiagnosticRunner(dict(zip(('Amount', 'Merchant'), before)),
                                          dict(zip(('Amount', 'Merchant'), after)))
                runner.run(w['WFWorkflowActions'])
                self.assertEqual(runner.requests, [])
                self.assertEqual(runner.delays, [5])
                self.assertIn('Запрос в Mora не отправлен', runner.notifications[-1])
                self.assertFalse(any('recorded' in n for n in runner.notifications))

    def test_separate_empty_then_complete_runs_only_deliver_the_complete_purchase(self):
        requests = []
        for fields in [('', ''), ('$2.99', 'Walgreens #19963')]:
            snapshot = dict(zip(('Amount', 'Merchant'), fields))
            runner = DiagnosticRunner(snapshot, snapshot)
            runner.run(wallet_delay_diagnostic(CONFIG)['WFWorkflowActions'])
            requests.extend(runner.requests)
        self.assertEqual(len(requests), 1)
        self.assertEqual((requests[0]['p_amount'], requests[0]['p_merchant']), ('$2.99', 'Walgreens #19963'))

    def test_reads_reference_original_wallet_input_on_both_sides_of_wait(self):
        actions = wallet_delay_diagnostic(CONFIG)['WFWorkflowActions']
        delay = next(i for i, a in enumerate(actions) if a['WFWorkflowActionIdentifier'].endswith('.delay'))
        reads = []
        for i, a in enumerate(actions):
            value = a['WFWorkflowActionParameters'].get('WFTextActionText', {})
            if isinstance(value, dict):
                for v in value.get('Value', {}).get('attachmentsByRange', {}).values():
                    if v.get('Type') == 'ExtensionInput': reads.append((i, v['Aggrandizements'][0]['PropertyName']))
        self.assertEqual([name for i, name in reads if i < delay], ['Amount', 'Merchant'])
        self.assertEqual([name for i, name in reads if i > delay], ['Amount', 'Merchant'])

    def test_preview_is_offline_and_contains_both_frozen_snapshots(self):
        w = wallet_delay_diagnostic(CONFIG, preview=True)
        self.assertEqual(w['WFWorkflowImportQuestions'], [])
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in w['WFWorkflowActions']]
        self.assertNotIn('downloadurl', kinds)
        self.assertNotIn('notification', kinds)
        runner = DiagnosticRunner({'Amount': '', 'Merchant': ''}, {'Amount': '$3.25', 'Merchant': 'PATH'})
        result = runner.run(w['WFWorkflowActions'])
        self.assertEqual(result['diagnostic_before'], 'amount=«»\nmerchant=«»')
        self.assertEqual(result['diagnostic_after'], 'amount=«$3.25»\nmerchant=«PATH»')
        self.assertEqual(result['diagnostic_comparison'], 'Поля изменились')

    def test_templates_keep_placeholder_and_delay_is_bounded(self):
        w = wallet_delay_diagnostic(CONFIG)
        self.assertEqual(w['WFWorkflowActions'][1]['WFWorkflowActionParameters']['WFTextActionText'], '0' * 64)
        self.assertEqual(w['WFWorkflowImportQuestions'][0]['ActionIndex'], 1)
        for value in (0, 11, 5.0, True):
            with self.subTest(delay=value), self.assertRaises(ValueError):
                wallet_delay_diagnostic(CONFIG, delay_seconds=value)


class PaymentDeliveryTests(unittest.TestCase):
    def test_quiet_delayed_sender_has_no_notifications_for_complete_or_missing_fields(self):
        for before, after, count in [(('', ''), ('', ''), 0),
                                     (('', ''), ('$2.99', ''), 0),
                                     (('', ''), ('$2.99', 'Walgreens'), 1),
                                     (('$2.99', 'Walgreens'), ('', ''), 1)]:
            with self.subTest(before=before, after=after):
                w = plistlib.loads(plistlib.dumps(wallet_delay(CONFIG), fmt=plistlib.FMT_BINARY))
                kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in w['WFWorkflowActions']]
                self.assertNotIn('notification', kinds)
                self.assertNotIn('showresult', kinds)
                runner = DiagnosticRunner(dict(zip(('Amount', 'Merchant'), before)),
                                          dict(zip(('Amount', 'Merchant'), after)))
                runner.run(w['WFWorkflowActions'])
                self.assertEqual(runner.notifications, [])
                self.assertEqual(len(runner.requests), count)
                self.assertEqual(runner.delays, [5])
                if count:
                    self.assertEqual((runner.requests[0]['p_amount'], runner.requests[0]['p_merchant']),
                                     ('$2.99', 'Walgreens'))

    def test_standard_senders_also_require_both_fields_without_collapsing_real_purchases(self):
        for wallet in (True, False):
            for amount, merchant, count in [('$2.99', 'Walgreens', 1), ('', '', 0),
                                          ('$2.99', '', 0), ('', 'Walgreens', 0),
                                          ('\n\t', 'Walgreens', 0), ('$2.99', '\u00a0', 0)]:
                with self.subTest(wallet=wallet, amount=amount, merchant=merchant):
                    fields = {'Amount' if wallet else 'amount': amount,
                              'Merchant' if wallet else 'merchant': merchant}
                    requests = []
                    # Two complete invocations remain two purchases, even with identical fields.
                    for _ in range(2):
                        runner = DiagnosticRunner(fields, fields)
                        runner.run(workflow(CONFIG, wallet=wallet)['WFWorkflowActions'])
                        requests.extend(runner.requests)
                    self.assertEqual(len(requests), 2 * count)

if __name__ == '__main__':
    unittest.main()

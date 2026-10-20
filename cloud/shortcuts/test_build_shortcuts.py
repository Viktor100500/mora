import unittest
from build_shortcuts import workflow

CONFIG = {'projectURL': 'https://example.supabase.co', 'publicKey': 'sb_publishable_example'}

class WorkflowTests(unittest.TestCase):
    def test_diagnostic_marks_start_before_wallet_extraction_and_reports_response_without_modal(self):
        actions = workflow(CONFIG, wallet=True, diagnostics=True)['WFWorkflowActions']
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
        self.assertNotIn('showresult', kinds)
        notes = [i for i, kind in enumerate(kinds) if kind == 'notification']
        self.assertEqual(len(notes), 2)
        self.assertLess(notes[0], 3)  # before Amount / Merchant can throw
        self.assertLess(kinds.index('downloadurl'), notes[1])
        body = actions[notes[1]]['WFWorkflowActionParameters']['WFNotificationActionBody']
        response = actions[kinds.index('downloadurl')]['WFWorkflowActionParameters']['UUID']
        self.assertEqual(next(iter(body['Value']['attachmentsByRange'].values()))['OutputUUID'], response)

    def test_preview_has_no_network_or_notifications(self):
        actions = workflow(CONFIG, preview=True, diagnostics=True)['WFWorkflowActions']
        kinds = [a['WFWorkflowActionIdentifier'].rsplit('.', 1)[-1] for a in actions]
        self.assertNotIn('downloadurl', kinds)
        self.assertNotIn('notification', kinds)
        self.assertEqual(kinds[-1], 'dictionary')

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
                    self.assertEqual(keys, ['amount', 'merchant', 'currency'])

if __name__ == '__main__':
    unittest.main()

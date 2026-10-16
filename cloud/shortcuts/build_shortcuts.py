"""Build native Shortcuts from the action format exported by Apple's editor.

Only public configuration is accepted. Phone secrets are entered after import,
never signed or sent to Apple. Signing is a separate official `shortcuts sign` step.
"""
import argparse
import json
import plistlib
import uuid
from pathlib import Path


def token(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def text(*parts):
    value, ranges = "", {}
    for part in parts:
        if isinstance(part, dict):
            ranges[f"{{{len(value.encode('utf-16-le')) // 2}, 1}}"] = part
            value += "\ufffc"
        else:
            value += part
    result = {"string": value}
    if ranges:
        result["attachmentsByRange"] = ranges
    return {"Value": result, "WFSerializationType": "WFTextTokenString"}


def dictionary(fields):
    return {"Value": {"WFDictionaryFieldValueItems": [
        {"WFItemType": 0, "WFKey": text(key),
         "WFValue": text(value) if isinstance(value, dict) else text(str(value))}
        for key, value in fields.items()
    ]}, "WFSerializationType": "WFDictionaryFieldValue"}


def workflow(config, preview=False, wallet=False):
    actions = []
    def action(identifier, output_name, **parameters):
        identifier_uuid = str(uuid.uuid4()).upper()
        actions.append({"WFWorkflowActionIdentifier": "is.workflow.actions." + identifier,
                        "WFWorkflowActionParameters": {"UUID": identifier_uuid, **parameters}})
        return {"Type": "ActionOutput", "OutputUUID": identifier_uuid, "OutputName": output_name}

    action('comment', '', WFCommentActionText=(
        ('Mora · Apple Pay\nПринимает транзакцию Wallet. Валюта пока требует проверки в Mora. ' if wallet else 'Mora · Apple Pay\nПринимает словарь amount, merchant, currency. ')
        + 'Неизвестную валюту оставляйте пустой: покупка сохранится во входящих. '
        'Ключ только записывает в выбранный счёт. '
        'Для первой версии требуется интернет; очередь повторной отправки не включена.'))
    phone = action('gettext', 'Ключ телефона', WFTextActionText='0' * 64)
    values = {}
    if wallet:
        # Wallet supplies a native Transaction content item. Use its properties,
        # as selected in the Shortcuts variable menu, rather than a dictionary cast.
        for key, property_name in [('amount', 'Amount'), ('merchant', 'Merchant')]:
            value = {"Type": "ExtensionInput", "Aggrandizements": [
                {"Type": "WFPropertyVariableAggrandizement", "PropertyName": property_name}]}
            values[key] = action('gettext', key, WFTextActionText=text(value))
        # Currency availability on the user's iPhone has not been verified.
        # Capture safely to the inbox instead of assuming account currency.
        values['currency'] = action('gettext', 'Валюта для проверки', WFTextActionText='')
    else:
        for key in ('amount', 'merchant', 'currency'):
            values[key] = action('getvalueforkey', key, WFDictionaryKey=key,
                                 WFInput=token({"Type": "ExtensionInput"}))
    date = action('format.date', 'Дата покупки', WFDate=text({"Type": "CurrentDate"}),
                  WFDateFormatStyle='ISO 8601', WFISO8601IncludeTime=True)
    random = action('number.random', 'Случайное число', WFRandomNumberMinimum='0',
                    WFRandomNumberMaximum='2147483647')
    seed = action('gettext', 'Основа события', WFTextActionText=text(date, '\n', random))
    digest = action('hash', 'Хеш события', WFHashType='SHA256', WFInput=token(seed))
    event = action('text.replace', 'Идентификатор события',
                   WFReplaceTextFind='^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*$',
                   WFReplaceTextReplace='$1-$2-4$3-8$4-$5',
                   WFReplaceTextRegularExpression=True, WFInput=text(digest))
    fields = {'p_token': phone, 'p_event_id': event, 'p_amount': values['amount'],
              'p_currency': values['currency'], 'p_merchant': values['merchant'],
              'p_occurred_at': date}
    if preview:
        action('dictionary', 'Тестовый запрос', WFItems=dictionary(fields))
    else:
        response = action('downloadurl', 'Ответ Mora', WFHTTPMethod='POST', WFHTTPBodyType='JSON',
               WFURL=config['projectURL'].rstrip('/') + '/rest/v1/rpc/mora_capture_payment',
               ShowHeaders=True,
               WFHTTPHeaders=dictionary({'apikey': config['publicKey'],
                                         'Content-Type': 'application/json'}),
               WFJSONValues=dictionary(fields))
        action('showresult', '', Text=text(
            'Mora · результат отправки\n', response,
            '\n\nrecorded — расход записан. pending — покупка во входящих Mora и требует проверки. '
            'Invalid phone token — проверьте ключ в первом действии «Текст»: там не должны оставаться нули.'))
    return {'WFWorkflowClientVersion': '4711', 'WFWorkflowMinimumClientVersion': 900,
            'WFWorkflowMinimumClientVersionString': '900',
            'WFWorkflowActions': actions, 'WFWorkflowTypes': ['WFWorkflowTypeShowInSearch'],
            'WFQuickActionSurfaces': [], 'WFWorkflowHasShortcutInputVariables': True,
            'WFWorkflowInputContentItemClasses': [] if wallet else ['WFDictionaryContentItem', 'WFStringContentItem', 'WFGenericFileContentItem'],
            'WFWorkflowOutputContentItemClasses': [], 'WFWorkflowHasOutputFallback': False,
            'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 61440, 'WFWorkflowIconStartColor': -12365313},
            'WFWorkflowImportQuestions': [] if preview else [
                {'ActionIndex': 1, 'Category': 'Parameter', 'ParameterKey': 'WFTextActionText',
                 'Text': 'Вставьте ключ телефона, созданный в Mora для нужной карты. Ключ только отправляет покупки в выбранный счёт.',
                 'DefaultValue': ''}]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    # Never accept privileged keys for a shareable artifact.
    assert config['projectURL'].startswith('https://') and config['projectURL'].endswith('.supabase.co')
    assert config['publicKey'].startswith('sb_publishable_')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for preview, wallet, name in [(False, True, 'Mora-ApplePay'), (False, False, 'Mora-ApplePay-Dictionary'), (True, False, 'Mora-Payload-Check')]:
        target = args.output_dir / (name + '.unsigned.shortcut')
        target.write_bytes(plistlib.dumps(workflow(config, preview, wallet), fmt=plistlib.FMT_BINARY))
        print(target)

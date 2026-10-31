"""Build native Shortcuts from the action format exported by Apple's editor.

Only public configuration is accepted; generated templates contain no phone keys.
Phone keys can be entered after import or added to a private copy before local
contacts-only signing. Never send private keys to iCloud notarization. Signing
is a separate official `shortcuts sign` step.
"""
import argparse
import copy
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


def guard_payment_delivery(actions, start, values, diagnostics=False):
    """Send only when both fields contain text, including after a delayed read.

    Keep the request and its response notification in the same guarded branch.
    Separate Wallet runs still have separate event IDs; do not guess payment
    identity from merchant, amount or a time bucket.
    """
    delivery = actions[start:]
    del actions[start:]

    def action(identifier, **parameters):
        identifier_uuid = str(uuid.uuid4()).upper()
        actions.append({'WFWorkflowActionIdentifier': 'is.workflow.actions.' + identifier,
                        'WFWorkflowActionParameters': {'UUID': identifier_uuid, **parameters}})
        return {'Type': 'ActionOutput', 'OutputUUID': identifier_uuid}

    groups = []
    for key in ('amount', 'merchant'):
        trimmed = action('text.replace', WFInput=text(values[key]),
                         WFReplaceTextFind=r'^\s+|\s+$', WFReplaceTextReplace='',
                         WFReplaceTextRegularExpression=True)
        group = str(uuid.uuid4()).upper()
        groups.append(group)
        action('conditional', GroupingIdentifier=group, WFControlFlowMode=0,
               WFCondition=100, WFInput={'Type': 'Variable', 'Variable': token(trimmed)})
    actions.extend(delivery)
    for group in reversed(groups):
        action('conditional', GroupingIdentifier=group, WFControlFlowMode=1)
        if diagnostics:
            action('notification', WFNotificationActionTitle='Mora · покупка не отправлена',
                   WFNotificationActionBody='Wallet не передал сумму или продавца. Запрос в Mora не отправлен.',
                   WFNotificationActionSound=False)
        action('conditional', GroupingIdentifier=group, WFControlFlowMode=2)


def workflow(config, preview=False, wallet=False, diagnostics=False):
    actions = []
    def action(identifier, output_name, **parameters):
        identifier_uuid = str(uuid.uuid4()).upper()
        actions.append({"WFWorkflowActionIdentifier": "is.workflow.actions." + identifier,
                        "WFWorkflowActionParameters": {"UUID": identifier_uuid, **parameters}})
        return {"Type": "ActionOutput", "OutputUUID": identifier_uuid, "OutputName": output_name}

    action('comment', '', WFCommentActionText=(
        ('Mora · Apple Pay\nПринимает транзакцию Wallet целиком: автоматизация из одного действия «Запустить команду» с входом «Входные данные команды». Читает сумму, продавца и карту; счет для карты выбирается в Mora. ' if wallet else 'Mora · Apple Pay\nПринимает словарь amount, merchant, card, currency. Один ключ на человека: счет выбирается в Mora для каждой карты. ')
        + 'Если код валюты неизвестен, оставьте поле пустым: сервер определит ее по сумме, если распознает символ или код. '
        'Ключ только записывает в выбранный счёт. '
        'Для первой версии требуется интернет; очередь повторной отправки не включена.'))
    phone = action('gettext', 'Ключ телефона', WFTextActionText='0' * 64)
    if diagnostics and not preview:
        action('notification', '', WFNotificationActionTitle='Mora · запуск',
               WFNotificationActionBody='Автоматизация запущена. Доставка покупки пока не подтверждена.',
               WFNotificationActionSound=False)
    values = {}
    if wallet:
        # Wallet supplies a native Transaction content item. Use its properties,
        # as selected in the Shortcuts variable menu, rather than a dictionary cast.
        for key, property_name in [('amount', 'Amount'), ('merchant', 'Merchant')]:
            value = {"Type": "ExtensionInput", "Aggrandizements": [
                {"Type": "WFPropertyVariableAggrandizement", "PropertyName": property_name}]}
            values[key] = action('gettext', key, WFTextActionText=text(value))
        # Currency availability on the user's iPhone has not been verified.
        # The server infers supported currencies from formatted amount text;
        # unknown symbols remain pending instead of being guessed.
        values['currency'] = action('gettext', 'Валюта для проверки', WFTextActionText='')
    else:
        for key in ('amount', 'merchant', 'currency', 'card'):
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
    if wallet:
        # Read last so the action indices used by the delay diagnostic stay unchanged.
        # The property is shown as "Card or Pass" in the Shortcuts variable menu.
        values['card'] = action('gettext', 'card', WFTextActionText=text({"Type": "ExtensionInput", "Aggrandizements": [
            {"Type": "WFPropertyVariableAggrandizement", "PropertyName": "Card or Pass"}]}))
    fields = {'p_token': phone, 'p_event_id': event, 'p_amount': values['amount'],
              'p_currency': values['currency'], 'p_merchant': values['merchant'],
              'p_occurred_at': date}
    if 'card' in values:
        # Requires the wallet_cards migration; an unknown card waits for an account in Mora.
        fields['p_card'] = values['card']
    delivery_start = len(actions)
    if preview:
        action('dictionary', 'Тестовый запрос', WFItems=dictionary(fields))
    else:
        response = action('downloadurl', 'Ответ Mora', WFHTTPMethod='POST', WFHTTPBodyType='JSON',
               WFURL=config['projectURL'].rstrip('/') + '/rest/v1/rpc/mora_capture_payment',
               ShowHeaders=True,
               WFHTTPHeaders=dictionary({'apikey': config['publicKey'],
                                         'Content-Type': 'application/json'}),
               WFJSONValues=dictionary(fields))
        # A modal result requires interaction and is unsuitable for locked-screen automation.
        # This reports the server response, not merely that the HTTP action ran.
        if diagnostics:
            action('notification', '', WFNotificationActionTitle='Mora · ответ сервера',
                   WFNotificationActionBody=text(response,
                       '\nrecorded — расход записан; pending — доставлено, ожидает обработки в Mora.'),
                   WFNotificationActionSound=False)
    guard_payment_delivery(actions, delivery_start, values, diagnostics=diagnostics and not preview)
    return {'WFWorkflowClientVersion': '4711', 'WFWorkflowMinimumClientVersion': 900,
            'WFWorkflowMinimumClientVersionString': '900',
            'WFWorkflowActions': actions, 'WFWorkflowTypes': ['WFWorkflowTypeShowInSearch'],
            'WFQuickActionSurfaces': [], 'WFWorkflowHasShortcutInputVariables': True,
            'WFWorkflowInputContentItemClasses': [] if wallet else ['WFDictionaryContentItem', 'WFStringContentItem', 'WFGenericFileContentItem'],
            'WFWorkflowOutputContentItemClasses': [], 'WFWorkflowHasOutputFallback': False,
            'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 61440, 'WFWorkflowIconStartColor': -12365313},
            'WFWorkflowImportQuestions': [] if preview else [
                {'ActionIndex': 1, 'Category': 'Parameter', 'ParameterKey': 'WFTextActionText',
                 'Text': 'Вставьте ключ телефона, созданный в Mora. Один ключ на человека — для всех его карт.',
                 'DefaultValue': ''}]}


def wallet_delay(config, delay_seconds=5, preview=False):
    """Quiet delayed sender; one network attempt without an offline queue."""
    return wallet_delay_diagnostic(config, delay_seconds, preview, diagnostics=False)


def wallet_delay_diagnostic(config, delay_seconds=5, preview=False, diagnostics=True):
    """Read Wallet twice; submit at most one payment, only with both fields present.

    This probes whether Wallet properties change during a run. It does not fetch
    a new transaction from Wallet or guarantee that iOS updates the input object.
    """
    if type(delay_seconds) is not int or not 1 <= delay_seconds <= 10:
        raise ValueError('The diagnostic delay must be an integer from 1 to 10 seconds')
    result = workflow(config, preview=preview, wallet=True)
    original = result['WFWorkflowActions']
    # Preserve the existing credential slot, request identity and capture endpoint.
    # Freeze the occurrence time and create the event ID once, before waiting.
    actions = copy.deepcopy(original[:2] + original[5:10])
    result['WFWorkflowActions'] = actions
    actions[0]['WFWorkflowActionParameters']['WFCommentActionText'] = (
        f'Mora · Wallet · {delay_seconds} с' + (' · диагностика' if diagnostics else ' · без уведомлений') + '\n'
        'Читает Amount и Merchant исходной транзакции сразу и после паузы. '
        'Отправляет только один запрос. Если повторное поле пустое, сохраняет первое значение. '
        'Если суммы или продавца всё ещё нет, ничего не отправляет. '
        'Дата покупки фиксируется до паузы. Это эксперимент, не чтение истории Wallet. '
        'Нужен интернет; офлайн-очереди нет. Не запускайте вручную без транзакции.')

    def reference(item, name):
        return {'Type': 'ActionOutput', 'OutputUUID': item['WFWorkflowActionParameters']['UUID'],
                'OutputName': name}

    def action(identifier, output_name='', **parameters):
        item = {'WFWorkflowActionIdentifier': 'is.workflow.actions.' + identifier,
                'WFWorkflowActionParameters': {'UUID': str(uuid.uuid4()).upper(), **parameters}}
        actions.append(item)
        return reference(item, output_name)

    phone = reference(actions[1], 'Ключ телефона')
    date = reference(actions[2], 'Дата покупки')
    event = reference(actions[6], 'Идентификатор события')

    def snapshot(label):
        values = {}
        for key, property_name in [('amount', 'Amount'), ('merchant', 'Merchant')]:
            # Each read addresses ExtensionInput again, never a converted Text
            # result or the output of Wait/notification.
            value = {'Type': 'ExtensionInput', 'Aggrandizements': [
                {'Type': 'WFPropertyVariableAggrandizement', 'PropertyName': property_name}]}
            values[key] = action('gettext', f'{property_name} · {label}', WFTextActionText=text(value))
        return values, action('gettext', f'Снимок · {label}',
                              WFTextActionText=text('amount=«', values['amount'],
                                                    '»\nmerchant=«', values['merchant'], '»'))

    before, before_text = snapshot('сразу')
    if diagnostics and not preview:
        action('notification', WFNotificationActionTitle='Mora · Wallet сразу',
               WFNotificationActionBody=text('Событие: ', event, '\n', before_text),
               WFNotificationActionSound=False)
    action('delay', WFDelayTime=delay_seconds)
    after, after_text = snapshot(f'через {delay_seconds} с')

    def choose(value, condition, yes, no, name, other=None):
        group = str(uuid.uuid4()).upper()
        parameters = {'GroupingIdentifier': group, 'WFControlFlowMode': 0,
                      'WFCondition': condition,
                      'WFInput': {'Type': 'Variable', 'Variable': token(value)}}
        if other is not None:
            parameters['WFConditionalActionString'] = text(other)
        action('conditional', **parameters)
        action('gettext', name, WFTextActionText=text(yes))
        action('conditional', GroupingIdentifier=group, WFControlFlowMode=1)
        action('gettext', name, WFTextActionText=text(no))
        return action('conditional', name, GroupingIdentifier=group, WFControlFlowMode=2)

    comparison = choose(before_text, 4, 'Без изменений', 'Поля изменились',
                        'Сравнение полей', other=after_text)  # native "is"
    selected = {key: choose(after[key], 100, after[key], before[key], f'{key} · к отправке')
                for key in ('amount', 'merchant')}  # native "has any value"
    report = action('gettext', 'Результат диагностики', WFTextActionText=text(
        'Событие: ', event, '\n', comparison, '\nСразу:\n', before_text,
        f'\nЧерез {delay_seconds} с:\n', after_text,
        '\nК отправке: «', selected['amount'], '» · «', selected['merchant'], '»'))
    if diagnostics and not preview:
        action('notification', WFNotificationActionTitle=f'Mora · Wallet через {delay_seconds} с',
               WFNotificationActionBody=text(report), WFNotificationActionSound=False)
    fields = {'p_token': phone, 'p_event_id': event, 'p_amount': selected['amount'],
              'p_currency': '', 'p_merchant': selected['merchant'], 'p_occurred_at': date}
    delivery_start = len(actions)
    if preview:
        # No credentials, network, or notifications in the validation variant.
        action('dictionary', 'Проверка диагностики', WFItems=dictionary({
            **fields, 'diagnostic_before': before_text, 'diagnostic_after': after_text,
            'diagnostic_comparison': comparison}))
    else:
        response = action('downloadurl', 'Ответ Mora', WFHTTPMethod='POST', WFHTTPBodyType='JSON',
                          WFURL=config['projectURL'].rstrip('/') + '/rest/v1/rpc/mora_capture_payment',
                          ShowHeaders=True,
                          WFHTTPHeaders=dictionary({'apikey': config['publicKey'],
                                                    'Content-Type': 'application/json'}),
                          WFJSONValues=dictionary(fields))
        if diagnostics:
            action('notification', WFNotificationActionTitle='Mora · ответ сервера',
                   WFNotificationActionBody=text('Событие: ', event, '\n', response,
                       '\nrecorded — расход записан; pending — доставлено во входящие.'),
                   WFNotificationActionSound=False)
    guard_payment_delivery(actions, delivery_start, selected, diagnostics=diagnostics and not preview)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--diagnostics', action='store_true',
                        help='Notify before reading Wallet fields to distinguish trigger and delivery failures')
    delayed = parser.add_mutually_exclusive_group()
    delayed.add_argument('--wallet-delay', action='store_true',
                        help='Quiet delayed Wallet sender without diagnostic notifications or an offline queue')
    delayed.add_argument('--wallet-delay-diagnostic', action='store_true',
                        help='Read Wallet before and after a delay; POST once only if amount and merchant are present')
    parser.add_argument('--delay-seconds', type=int, default=5,
                        help='Delay for the repeated Wallet read (1–10 seconds, default 5)')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    # Never accept privileged keys for a shareable artifact.
    assert config['projectURL'].startswith('https://') and config['projectURL'].endswith('.supabase.co')
    assert config['publicKey'].startswith('sb_publishable_')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.wallet_delay or args.wallet_delay_diagnostic:
        suffix = 'Diagnostic' if args.wallet_delay_diagnostic else 'Quiet'
        target = args.output_dir / f'Mora-Wallet-{args.delay_seconds}s-{suffix}.unsigned.shortcut'
        builder = wallet_delay_diagnostic if args.wallet_delay_diagnostic else wallet_delay
        target.write_bytes(plistlib.dumps(builder(config, args.delay_seconds),
                                         fmt=plistlib.FMT_BINARY))
        print(target)
        raise SystemExit(0)
    for preview, wallet, name in [(False, True, 'Mora-ApplePay'), (False, False, 'Mora-ApplePay-Dictionary'), (True, False, 'Mora-Payload-Check')]:
        if args.diagnostics and not preview:
            name += '-Diagnostic'
        target = args.output_dir / (name + '.unsigned.shortcut')
        target.write_bytes(plistlib.dumps(workflow(config, preview, wallet, args.diagnostics), fmt=plistlib.FMT_BINARY))
        print(target)

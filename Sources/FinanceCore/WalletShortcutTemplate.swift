import Foundation

/// Configure the public, generated Apple shortcut without changing its control flow.
public enum WalletShortcutTemplate {
    public static func configured(_ data: Data, configuration: CloudConfiguration, phoneToken: String) throws -> Data {
        guard phoneToken.count == 64, phoneToken.allSatisfy({ $0.isHexDigit }) else {
            throw LedgerError.invalid("Неверный ключ телефона.")
        }
        guard var workflow = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var actions = workflow["WFWorkflowActions"] as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
        var keys = 0, requests = 0
        for i in actions.indices {
            guard var parameters = actions[i]["WFWorkflowActionParameters"] as? [String: Any] else { continue }
            if actions[i]["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.gettext",
               parameters["WFTextActionText"] as? String == String(repeating: "0", count: 64) {
                parameters["WFTextActionText"] = phoneToken; keys += 1
            }
            if actions[i]["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.downloadurl" {
                requests += 1
                parameters["WFURL"] = configuration.projectURL.appendingPathComponent("rest/v1/rpc/mora_capture_payment").absoluteString
                guard var headers = parameters["WFHTTPHeaders"] as? [String: Any],
                      var value = headers["Value"] as? [String: Any],
                      var items = value["WFDictionaryFieldValueItems"] as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
                var replaced = false
                for j in items.indices {
                    if let key = items[j]["WFKey"] as? [String: Any],
                       let text = key["Value"] as? [String: Any], text["string"] as? String == "apikey" {
                        items[j]["WFValue"] = ["WFSerializationType": "WFTextTokenString", "Value": ["string": configuration.publicKey]]
                        replaced = true
                    }
                }
                guard replaced else { throw CloudAPIError.invalidResponse }
                value["WFDictionaryFieldValueItems"] = items; headers["Value"] = value
                parameters["WFHTTPHeaders"] = headers
            }
            actions[i]["WFWorkflowActionParameters"] = parameters
        }
        guard keys == 1, requests == 1 else { throw CloudAPIError.invalidResponse }
        workflow["WFWorkflowActions"] = actions
        workflow["WFWorkflowImportQuestions"] = []
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }
}

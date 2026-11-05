import SwiftUI
import FinanceCore

struct MerchantSettingsCard: View {
    @EnvironmentObject private var categorizer: MerchantCategorizer
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: L("Автоматические категории"), subtitle: L("Для знакомого продавца используется категория из истории"))
                Toggle(L("Определять категории новых продавцов"), isOn: $categorizer.onlineEnabled)
                Text(L("Встроенная база заведений Нью-Йорка и окрестностей и продуктовых магазинов штата работает без интернета. Каталоги брендов обновляются в фоне. Названия покупок, суммы и счета никуда не отправляются."))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = categorizer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Link("Enrichment from Merchant Studio by Jonathan Taveras", destination: URL(string: "https://github.com/jtvargas/merchant-studio")!).font(.caption)
                Link("OpenStreetMap Name Suggestion Index · BSD-3-Clause", destination: URL(string: "https://github.com/osmlab/name-suggestion-index")!).font(.caption)
                Link("Overture Places · CDLA Permissive 2.0 / Apache 2.0", destination: URL(string: "https://docs.overturemaps.org/guides/places/")!).font(.caption)
                Link("NYS Retail Food Stores · Open NY", destination: URL(string: "https://data.ny.gov/Economic-Development/Retail-Food-Stores/9a8c-vfzj")!).font(.caption)
            }
        }
    }
}

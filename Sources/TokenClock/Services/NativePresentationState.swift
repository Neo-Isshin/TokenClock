#if !canImport(Combine)
import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
func toolboxText(_ cn: String, _ en: String) -> String { L10n.shared.language.rawValue.hasPrefix("zh") ? cn : en }
#endif

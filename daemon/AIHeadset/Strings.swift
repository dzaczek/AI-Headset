import Foundation

/// Thin wrapper over NSLocalizedString so call sites stay short.
/// Translations live in Resources/{pl,en}.lproj/Localizable.strings;
/// macOS picks one based on the user's system language, falling back
/// to the development language (English) for anything missing.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

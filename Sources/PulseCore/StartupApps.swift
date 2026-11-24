import Foundation
import Security

/// Startup items that live inside apps. An app registers them from its own bundle, so they are in
/// none of the folders. Only what launchd has loaded now can be seen: the full list needs an administrator.
enum StartupApps {
    struct Found: Equatable {
        var label: String
        var app: String
        /// The program or helper app, for its signature. "" when the plist names none.
        var program: String
    }

    /// What the apps in these folders, and one folder further down, can register.
    static func find(in roots: [String]) -> [Found] {
        let fm = FileManager.default
        func list(_ dir: String, _ suffix: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().filter { $0.hasSuffix(suffix) }.map { dir + "/" + $0 }
        }
        var apps: [String] = []
        for root in roots {
            apps += list(root, ".app")
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.contains(".") { apps += list(root + "/" + name, ".app") }
        }
        var out: [Found] = []
        for app in apps {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension, library = app + "/Contents/Library/"
            for path in list(library + "LaunchAgents", ".plist") + list(library + "LaunchDaemons", ".plist") {
                guard let p = HealthProbe.plist(path), let label = p["Label"] as? String, !label.isEmpty else { continue }
                let inside = (p["BundleProgram"] as? String).map { app + "/" + $0 }
                out.append(Found(label: label, app: name, program: inside ?? p["Program"] as? String ?? (p["ProgramArguments"] as? [String])?.first ?? ""))
            }
            for helper in list(library + "LoginItems", ".app") {
                guard let id = HealthProbe.plist(helper + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
                out.append(Found(label: id, app: name, program: helper))
            }
        }
        return out
    }

    /// The folders' items marked as loaded or not, then what is loaded from inside an app. A label that
    /// is loaded and in neither place is left out: one-off updaters come and go, and would be news each time.
    static func join(folders: [StartupItem], apps: [Found], loaded: Set<String>, signer: (String) -> String?) -> [StartupItem] {
        var out = folders.map { item -> StartupItem in
            var i = item
            i.loaded = loaded.contains(i.label)
            if i.loaded == true { i.signer = signer(i.program) }
            return i
        }
        var seen = Set(folders.map(\.label))
        for f in apps where loaded.contains(f.label) && seen.insert(f.label).inserted {
            out.append(StartupItem(label: f.label, program: f.program, missing: false, app: f.app, loaded: true, signer: signer(f.program)))
        }
        return out
    }

    /// "Signed by Example Inc", "Not signed by a known developer", or nil when it cannot be said. A fact
    /// beside the row and no more: tools built on this Mac are not signed by anyone.
    static func signer(of program: String) -> String? {
        guard program.hasPrefix("/"), FileManager.default.fileExists(atPath: program) else { return nil }
        // Runs a script: the signature of the shell says nothing about it.
        if program.hasPrefix("/bin/") || program.hasPrefix("/usr/bin/") { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: program) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var apple: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &apple) == errSecSuccess else { return nil }
        // Not every file inside a large app, and nothing is asked over the network.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | UInt32(1 << 29))
        guard SecStaticCodeCheckValidity(code, flags, apple) == errSecSuccess else { return "Not signed by a known developer" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        return "Signed by " + developer(summary)
    }

    /// "Developer ID Application: Example Inc (ABCDE12345)"
    static func developer(_ summary: String) -> String {
        if summary == "Software Signing" { return "Apple" }
        let name = summary.split(separator: ":", maxSplits: 1).last.map(String.init) ?? summary
        return name.replacingOccurrences(of: #"\s*\([A-Z0-9]{10}\)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

// UpdateChecker.swift
// DataHawk
//
// Checks the GitHub Releases API for a newer version of DataHawk.
//
// Two entry points (both on `UpdateChecker`):
//   - checkForUpdates()         — called once at launch (5 s delay), silently
//                                 sets AppState.updateDownloadURL when a newer
//                                 DMG is available.
//   - checkForUpdatesManually() — called from the About tab, reports the result
//                                 via callbacks so the caller can update its UI.

import Foundation

// MARK: - UpdateChecker

enum UpdateChecker {

    // MARK: - Configuration

    private static let releasesURL =
        "https://api.github.com/repos/valeriansaliou/datahawk/releases/latest"

    // MARK: - Result type

    private enum ReleaseResult {
        case newer(downloadURL: String)
        case upToDate
        case error
    }

    // MARK: - Public entry points

    /// Waits 5 s after launch, then checks for a newer release. When one is
    /// found, sets `AppState.updateDownloadURL` so the popover banner appears.
    static func checkForUpdates() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fetchRelease { result in
                guard case .newer(let url) = result else { return }
                DispatchQueue.main.async { AppState.shared.updateDownloadURL = url }
            }
        }
    }

    /// Fetches the latest release and reports the result via callbacks on the
    /// main thread.
    ///
    /// - Parameters:
    ///   - onFound:    Called with the DMG download URL when a newer version exists.
    ///   - onUpToDate: Called when the running version is already the latest.
    ///   - onError:    Called when the network request or JSON parsing fails.
    static func checkForUpdatesManually(
        onFound:    @escaping (_ downloadURL: String) -> Void,
        onUpToDate: @escaping () -> Void,
        onError:    @escaping () -> Void
    ) {
        fetchRelease { result in
            DispatchQueue.main.async {
                switch result {
                case .newer(let url): onFound(url)
                case .upToDate:       onUpToDate()
                case .error:          onError()
                }
            }
        }
    }

    // MARK: - Shared fetch

    private static func fetchRelease(_ completion: @escaping (ReleaseResult) -> Void) {
        guard let url = URL(string: releasesURL) else { completion(.error); return }

        let version = bundleShortVersion ?? "0"
        var request = URLRequest(url: url)
        request.setValue("DataHawk/\(version)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data,
                  let json        = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag         = json["tag_name"] as? String,
                  let assets      = json["assets"]   as? [[String: Any]],
                  let dmg         = assets.first(where: {
                      ($0["name"] as? String)?.hasSuffix(".dmg") == true
                  }),
                  let downloadURL = dmg["browser_download_url"] as? String
            else {
                completion(.error)
                return
            }

            let current = bundleShortVersion ?? ""
            completion(isNewerVersion(tag, than: current)
                       ? .newer(downloadURL: downloadURL)
                       : .upToDate)
        }.resume()
    }

    // MARK: - Helpers

    private static var bundleShortVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Returns `true` if `remote` is strictly newer than `local`. Supports any
    /// number of semver components; missing ones are treated as zero.
    private static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let r = versionComponents(remote)
        let l = versionComponents(local)

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }

        return false
    }

    /// Splits a version string into integer components, stripping a leading "v".
    private static func versionComponents(_ s: String) -> [Int] {
        let stripped = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return stripped.split(separator: ".").compactMap { Int($0) }
    }
}

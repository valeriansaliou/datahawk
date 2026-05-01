// UpdateChecker.swift
// DataHawk
//
// Checks the GitHub Releases API for a newer version of DataHawk.
//
// Two entry points:
//   - checkForUpdates()         — called once at launch (5 s delay), silently
//                                 sets AppState.updateDownloadURL when a newer
//                                 DMG is available.
//   - checkForUpdatesManually() — called from the About tab, reports the result
//                                 via callbacks so the caller can update its UI.

import Foundation

// MARK: - GitHub API

private let kReleasesURL =
    "https://api.github.com/repos/valeriansaliou/datahawk/releases/latest"

// MARK: - Version comparison

/// Returns `true` if `remote` is strictly newer than `local`.
/// Supports any number of semver components; missing ones are treated as zero.
private func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let strip = { (s: String) -> String in s.hasPrefix("v") ? String(s.dropFirst()) : s }
    let parts = { (s: String) -> [Int] in
        strip(s).split(separator: ".").compactMap { Int($0) }
    }

    let r = parts(remote), l = parts(local)

    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv != lv { return rv > lv }
    }

    return false
}

// MARK: - Shared fetch

private enum ReleaseResult {
    case newer(downloadURL: String)
    case upToDate
    case error
}

private func fetchRelease(_ completion: @escaping (ReleaseResult) -> Void) {
    guard let url = URL(string: kReleasesURL) else { completion(.error); return }

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var request = URLRequest(url: url)
    request.setValue("DataHawk/\(version)", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: request) { data, _, error in
        guard error == nil,
              let data,
              let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag        = json["tag_name"] as? String,
              let assets     = json["assets"]   as? [[String: Any]],
              let dmg        = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true
              }),
              let downloadURL = dmg["browser_download_url"] as? String
        else {
            completion(.error)
            return
        }

        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        completion(isNewerVersion(tag, than: current) ? .newer(downloadURL: downloadURL) : .upToDate)
    }.resume()
}

// MARK: - Automatic check (launch-time)

/// Waits 5 s after launch, then checks for a newer release. When one is found,
/// sets `AppState.updateDownloadURL` so the popover banner appears.
func checkForUpdates() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        fetchRelease { result in
            guard case .newer(let url) = result else { return }
            DispatchQueue.main.async { AppState.shared.updateDownloadURL = url }
        }
    }
}

// MARK: - Manual check (user-triggered)

/// Fetches the latest release and reports the result via callbacks on the main thread.
///
/// - Parameters:
///   - onFound:    Called with the DMG download URL when a newer version exists.
///   - onUpToDate: Called when the running version is already the latest.
///   - onError:    Called when the network request or JSON parsing fails.
func checkForUpdatesManually(
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

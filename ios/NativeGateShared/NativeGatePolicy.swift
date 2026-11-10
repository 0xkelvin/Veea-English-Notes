import Foundation

struct NativeGateApplication: Codable, Equatable, Identifiable {
  let id: String
  let token: Data
}

struct NativeGatePass: Codable, Equatable {
  let expiresAt: Date
  let activityName: String
}

struct NativeGatePendingChallenge: Codable, Equatable {
  let applicationID: String
  let createdAt: Date
}

struct NativeGateState: Codable, Equatable {
  var enabled = false
  var passMinutes = 15
  var applications: [NativeGateApplication] = []
  var passes: [String: NativeGatePass] = [:]
  var pendingChallenge: NativeGatePendingChallenge?

  func shieldedApplicationIDs(at now: Date) -> Set<String> {
    guard enabled else { return [] }
    return Set(applications.map(\.id).filter { id in
      guard let pass = passes[id] else { return true }
      return pass.expiresAt <= now
    })
  }

  mutating func reconcile(at now: Date) {
    passMinutes = NativeGatePolicy.normalizedPassMinutes(passMinutes)
    let selected = Set(applications.map(\.id))
    passes = passes.filter { selected.contains($0.key) && $0.value.expiresAt > now }
    if let pending = pendingChallenge,
       !selected.contains(pending.applicationID) || now.timeIntervalSince(pending.createdAt) > 120 {
      pendingChallenge = nil
    }
  }

  mutating func consumeChallenge(at now: Date) -> String? {
    defer { pendingChallenge = nil }
    guard let pending = pendingChallenge,
          now.timeIntervalSince(pending.createdAt) >= 0,
          now.timeIntervalSince(pending.createdAt) <= 120,
          shieldedApplicationIDs(at: now).contains(pending.applicationID) else { return nil }
    return "native:\(pending.applicationID)"
  }
}

enum NativeGatePolicy {
  // DeviceActivity requires monitoring intervals of at least fifteen minutes.
  // Apple permits up to one week; launch intentionally caps access at 24 hours.
  static let supportedPassMinutes = 5...1440
  static let minimumMonitoringMinutes = 15
  static let maximumApplications = 50

  static func normalizedPassMinutes(_ minutes: Int) -> Int {
    min(max(minutes, supportedPassMinutes.lowerBound), supportedPassMinutes.upperBound)
  }

  // Use an explicit fixed calendar so a repeated local DST hour cannot resolve
  // to a different instant. DeviceActivity uses the components' calendar.
  static func scheduleComponents(for date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
  }

  static func validateApplicationCount(_ count: Int) throws {
    guard count <= maximumApplications else { throw NativeGateError.tooManyApplications }
  }

  static func applicationID(from target: String) -> String? {
    guard target.hasPrefix("native:") else { return nil }
    let id = String(target.dropFirst("native:".count))
    return UUID(uuidString: id) == nil ? nil : id
  }
}

import Foundation

struct NativeGateGrantCoordinator {
  let store: NativeGateStore

  func grant(
    applicationID: String,
    minutes: Int,
    now: Date = Date(),
    startMonitoring: (String, Date, Date) throws -> Void,
    stopMonitoring: (String) -> Void,
    apply: (NativeGateState) -> Void
  ) throws -> NativeGatePass {
    guard NativeGatePolicy.supportedPassMinutes.contains(minutes) else {
      throw NativeGateError.invalidDuration
    }
    let snapshot = try store.read()
    guard snapshot.enabled,
          snapshot.applications.contains(where: { $0.id == applicationID }) else {
      throw NativeGateError.unknownApplication
    }
    let start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    // Align persisted expiry with the schedule's whole-second end. Otherwise an
    // early callback could see a fractional-second pass still valid and miss it.
    let expiry = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970) + Double(minutes * 60))
    let pass = NativeGatePass(
      expiresAt: expiry, activityName: "veea.native.\(applicationID).\(UUID().uuidString)"
    )
    try startMonitoring(pass.activityName, start, expiry)
    do {
      let oldActivity = try store.update({ state -> String? in
        guard state.enabled,
              state.applications.contains(where: { $0.id == applicationID }) else {
          throw NativeGateError.unknownApplication
        }
        let previous = state.passes[applicationID]?.activityName
        state.passes[applicationID] = pass
        state.pendingChallenge = nil
        return previous
      }, apply: apply)
      if let previous = oldActivity { stopMonitoring(previous) }
      return pass
    } catch {
      stopMonitoring(pass.activityName)
      throw error
    }
  }
}

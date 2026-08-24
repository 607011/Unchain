import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case unavailable
    case authorizationDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Health data isn't available on this device."
        case .authorizationDenied: return "Bahoo isn't allowed to save workouts to Health."
        case .saveFailed: return "The workout couldn't be saved."
        }
    }
}

/// Thin wrapper around HealthKit for saving completed trainer/treadmill
/// workouts to Apple Health (shown in the Fitness app as "Indoor Cycling",
/// "Indoor Walk", or "Indoor Run"). Write-only – the app never reads health data.
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var typesToShare: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let distanceCycling = HKObjectType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(distanceCycling)
        }
        if let distanceWalkingRunning = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distanceWalkingRunning)
        }
        return types
    }

    /// Requests authorization (if needed) and saves the workout, including any
    /// heart rate samples collected during the session. Completion is always
    /// called on the main thread.
    func save(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isAvailable else {
            completion(.failure(HealthKitError.unavailable))
            return
        }
        store.requestAuthorization(toShare: typesToShare, read: []) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard granted else {
                DispatchQueue.main.async { completion(.failure(HealthKitError.authorizationDenied)) }
                return
            }
            self.saveWorkout(summary, as: activityType, completion: completion)
        }
    }

    private func saveWorkout(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType, completion: @escaping (Result<Void, Error>) -> Void) {
        let totalDistance = summary.distanceMeters.map { HKQuantity(unit: .meter(), doubleValue: $0) }

        let workout = HKWorkout(
            activityType: activityType,
            start: summary.startDate,
            end: summary.endDate,
            duration: summary.activeDuration,
            totalEnergyBurned: nil,
            totalDistance: totalDistance,
            metadata: [HKMetadataKeyIndoorWorkout: true]
        )

        store.save(workout) { [weak self] success, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard success else {
                DispatchQueue.main.async { completion(.failure(HealthKitError.saveFailed)) }
                return
            }
            self.addHeartRateSamples(summary.heartRateSamples, to: workout) { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func addHeartRateSamples(_ samples: [(date: Date, bpm: Int)], to workout: HKWorkout, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !samples.isEmpty, let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            completion(.success(()))
            return
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let quantitySamples = samples.map { sample in
            HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: unit, doubleValue: Double(sample.bpm)),
                start: sample.date,
                end: sample.date
            )
        }
        store.add(quantitySamples, to: workout) { success, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}

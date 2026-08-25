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
/// "Indoor Walk", or "Indoor Run"), including an active-energy (calorie)
/// estimate. What this reads back from Health: the user's most recent body
/// weight (needed for the walk/run calorie formula) and date of birth (for an
/// estimated max heart rate, used for the in-app heart rate zones – Health
/// itself has no "time in zone" concept to write to). Both are read rather
/// than asked for again since Health already has a dedicated place for them.
/// Apple's own Fitness app then adds its own resting-calorie estimate on top
/// of our active-energy figure to show a "Total" for the workout, using
/// whatever profile (age/sex/height/weight) the user has in their Health
/// Details – nothing this app needs to duplicate.
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var typesToShare: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(activeEnergy)
        }
        if let distanceCycling = HKObjectType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(distanceCycling)
        }
        if let distanceWalkingRunning = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distanceWalkingRunning)
        }
        return types
    }

    private var typesToRead: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) {
            types.insert(bodyMass)
        }
        if let dateOfBirth = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            types.insert(dateOfBirth)
        }
        return types
    }

    /// Requests full authorization eagerly (the same share/read sets `save()`
    /// uses, so a later save doesn't need to prompt again) and returns an
    /// estimated max heart rate from the user's date of birth (crude
    /// 220−age formula) for live in-app heart rate zones. There's no
    /// HealthKit type for "the user's configured max heart rate" to read
    /// instead – this is the best available proxy without asking the user to
    /// enter it themselves.
    func fetchMaxHeartRateBPM(completion: @escaping (Int?) -> Void) {
        guard isAvailable else {
            completion(nil)
            return
        }
        store.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] granted, _ in
            guard let self, granted else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let maxHeartRateBPM = self.readMaxHeartRateBPM()
            DispatchQueue.main.async { completion(maxHeartRateBPM) }
        }
    }

    private func readMaxHeartRateBPM() -> Int? {
        guard let components = try? store.dateOfBirthComponents(), let birthYear = components.year else {
            return nil
        }
        let age = Calendar.current.component(.year, from: Date()) - birthYear
        guard age > 0 else { return nil }
        return 220 - age
    }

    /// Requests authorization (if needed), estimates active energy burned, and
    /// saves the workout along with any heart rate samples collected during
    /// the session. Completion is always called on the main thread.
    func save(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isAvailable else {
            completion(.failure(HealthKitError.unavailable))
            return
        }
        store.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard granted else {
                DispatchQueue.main.async { completion(.failure(HealthKitError.authorizationDenied)) }
                return
            }
            self.estimateActiveEnergyKcal(for: summary, as: activityType) { activeEnergyKcal in
                self.saveWorkout(summary, as: activityType, activeEnergyKcal: activeEnergyKcal, completion: completion)
            }
        }
    }

    /// Cycling needs no biometric data (power → work → kcal, see
    /// `EnergyEstimator`). Walking/running needs body weight, fetched from
    /// Health; if there's no weight on record there, the workout is still
    /// saved, just without a calorie figure – no invented fallback number.
    private func estimateActiveEnergyKcal(for summary: WorkoutSummary, as activityType: HKWorkoutActivityType, completion: @escaping (Double?) -> Void) {
        switch activityType {
        case .cycling:
            if let kilojoules = summary.workDoneKilojoules {
                completion(EnergyEstimator.cyclingActiveEnergyKcal(workDoneKilojoules: kilojoules))
            } else {
                completion(nil)
            }
        case .walking, .running:
            guard let distanceMeters = summary.distanceMeters else {
                completion(nil)
                return
            }
            fetchLatestBodyMassKg { weightKg in
                guard let weightKg else {
                    completion(nil)
                    return
                }
                completion(EnergyEstimator.walkRunActiveEnergyKcal(
                    isRunning: activityType == .running,
                    distanceMeters: distanceMeters,
                    duration: summary.activeDuration,
                    weightKg: weightKg
                ))
            }
        default:
            completion(nil)
        }
    }

    private func fetchLatestBodyMassKg(completion: @escaping (Double?) -> Void) {
        guard let bodyMassType = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            completion(nil)
            return
        }
        let sortByMostRecent = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: bodyMassType, predicate: nil, limit: 1, sortDescriptors: [sortByMostRecent]) { _, samples, _ in
            let kg = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: .gramUnit(with: .kilo))
            DispatchQueue.main.async { completion(kg) }
        }
        store.execute(query)
    }

    private func saveWorkout(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType, activeEnergyKcal: Double?, completion: @escaping (Result<Void, Error>) -> Void) {
        let totalDistance = summary.distanceMeters.map { HKQuantity(unit: .meter(), doubleValue: $0) }
        let totalEnergyBurned = activeEnergyKcal.map { HKQuantity(unit: .kilocalorie(), doubleValue: $0) }

        var metadata: [String: Any] = [HKMetadataKeyIndoorWorkout: true]
        if let programName = summary.programName {
            // Not literally what this key is documented for (it's meant for a
            // studio/instructor/class name, e.g. Fitness+ partner workouts),
            // but it's the metadata key the Fitness app actually renders as a
            // subtitle under the workout type – there's no generic "notes" or
            // "description" field in HealthKit that's surfaced anywhere.
            metadata[HKMetadataKeyWorkoutBrandName] = programName
        }

        let workout = HKWorkout(
            activityType: activityType,
            start: summary.startDate,
            end: summary.endDate,
            duration: summary.activeDuration,
            totalEnergyBurned: totalEnergyBurned,
            totalDistance: totalDistance,
            metadata: metadata
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
            self.addSupplementarySamples(heartRateSamples: summary.heartRateSamples, activeEnergyKcal: activeEnergyKcal, to: workout) { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Adds heart rate samples and, separately, an active-energy quantity
    /// sample spanning the whole workout. The latter isn't just for show in
    /// the workout detail view – it's also what makes the calories count
    /// toward the user's daily Activity (Move) ring, which `HKWorkout
    /// .totalEnergyBurned` alone does not do.
    private func addSupplementarySamples(heartRateSamples: [(date: Date, bpm: Int)], activeEnergyKcal: Double?, to workout: HKWorkout, completion: @escaping (Result<Void, Error>) -> Void) {
        var samples: [HKSample] = []

        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            let unit = HKUnit.count().unitDivided(by: .minute())
            samples += heartRateSamples.map { sample in
                HKQuantitySample(
                    type: heartRateType,
                    quantity: HKQuantity(unit: unit, doubleValue: Double(sample.bpm)),
                    start: sample.date,
                    end: sample.date
                )
            }
        }

        if let activeEnergyKcal, let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            samples.append(HKQuantitySample(
                type: activeEnergyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: activeEnergyKcal),
                start: workout.startDate,
                end: workout.endDate
            ))
        }

        guard !samples.isEmpty else {
            completion(.success(()))
            return
        }
        store.add(samples, to: workout) { success, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}

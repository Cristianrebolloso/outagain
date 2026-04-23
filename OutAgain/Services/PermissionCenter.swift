import Contacts
import CoreLocation
import Observation
import UserNotifications

@MainActor
@Observable
final class PermissionCenter: NSObject, CLLocationManagerDelegate {
    var contactsStatus: PermissionState
    var locationStatus: PermissionState
    var notificationsStatus: PermissionState
    var currentLocation: CLLocation?

    @ObservationIgnored private let contactStore = CNContactStore()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let notificationCenter = UNUserNotificationCenter.current()

    override init() {
        contactsStatus = PermissionCenter.mapContactsStatus(CNContactStore.authorizationStatus(for: .contacts))
        locationStatus = .notDetermined
        notificationsStatus = .notDetermined
        currentLocation = nil
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationStatus = PermissionCenter.mapLocationStatus(locationManager.authorizationStatus)

        Task {
            await refreshNotificationStatus()
        }
    }

    func requestContacts() async {
        guard contactsStatus == .notDetermined else { return }

        let granted = await withCheckedContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }

        contactsStatus = granted ? .granted : .denied
    }

    func requestLocation() {
        switch locationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .granted:
            locationManager.requestLocation()
        case .denied:
            break
        }
    }

    func requestNotifications() async {
        guard notificationsStatus == .notDetermined else { return }

        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            notificationsStatus = granted ? .granted : .denied
        } catch {
            notificationsStatus = .denied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = PermissionCenter.mapLocationStatus(manager.authorizationStatus)

        if locationStatus == .granted {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Keep the last successful location and fail quietly for the MVP flow.
    }

    private func refreshNotificationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        notificationsStatus = PermissionCenter.mapNotificationStatus(settings.authorizationStatus)
    }

    private static func mapContactsStatus(_ status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .limited:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }

    private static func mapLocationStatus(_ status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }

    private static func mapNotificationStatus(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            .granted
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}

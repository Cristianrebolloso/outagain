import CoreLocation
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class PermissionCenter: NSObject, CLLocationManagerDelegate {
    private struct LocationAuthorizationSnapshot {
        var servicesEnabled: Bool
        var authorizationStatus: CLAuthorizationStatus
    }

    var locationStatus: PermissionState
    var notificationsStatus: PermissionState
    var currentLocation: CLLocation?
    var locationErrorMessage: String?
    /// Human-readable locality for `currentLocation`, formatted as
    /// "City, ST" once resolved. Nil until reverse geocoding succeeds,
    /// so views can show a "Finding place" state while it resolves.
    var currentLocality: String?

    var currentLocationSnapshot: LocationSnapshot? {
        guard let currentLocation else { return nil }
        return LocationSnapshot(location: currentLocation)
    }

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let notificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored private var isRefreshingLocationAuthorization = false
    @ObservationIgnored private let geocoder = CLGeocoder()
    /// The coordinate that produced `currentLocality`. Used so we only
    /// re-geocode when the viewer has actually moved a meaningful
    /// distance, keeping us well under CLGeocoder's rate limits.
    @ObservationIgnored private var lastGeocodedLocation: CLLocation?
    /// A re-geocode triggers only after the viewer moves this far from
    /// the coordinate that produced the cached locality. 250m is tuned
    /// to fire on neighborhood-level change without burning quota on
    /// every sidewalk step.
    @ObservationIgnored private static let localityRefetchDistance: CLLocationDistance = 250

    override init() {
        locationStatus = .notDetermined
        notificationsStatus = .notDetermined
        currentLocation = nil
        locationErrorMessage = nil
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 25
        locationManager.activityType = .other

        Task {
            await refreshLocationAuthorization(startUpdatesIfAuthorized: true)
        }

        Task {
            await refreshNotificationStatus()
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func requestLocation() {
        Task {
            await refreshLocationAuthorization(
                startUpdatesIfAuthorized: true,
                requestAuthorizationIfNeeded: true
            )
        }
    }

    func requestNotifications() async {
        if notificationsStatus == .notDetermined {
            do {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                notificationsStatus = granted ? .granted : .denied
            } catch {
                notificationsStatus = .denied
            }
        }

        if notificationsStatus == .granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Re-request APNs registration on every cold launch when the user has already opted in.
    /// Apple recommends calling this each launch so the token is refreshed if rotated.
    func reregisterRemoteNotificationsIfAuthorized() async {
        await refreshNotificationStatus()
        if notificationsStatus == .granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = PermissionCenter.mapLocationStatus(manager.authorizationStatus)

        if locationStatus == .granted {
            locationErrorMessage = nil
            startLocationUpdates()
        } else if locationStatus == .denied {
            locationErrorMessage = "Allow location in Settings to see distance and nearby places."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let freshLocations = locations.filter { location in
            location.horizontalAccuracy >= 0 && abs(location.timestamp.timeIntervalSinceNow) < 30
        }

        if let bestLocation = freshLocations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            currentLocation = bestLocation
        } else {
            currentLocation = locations.last
        }

        locationErrorMessage = nil
        refreshLocalityIfNeeded()
    }

    /// Reverse-geocodes `currentLocation` into a "City, ST" string and
    /// caches it on `currentLocality`. We only re-fire the request when
    /// the viewer has moved more than `localityRefetchDistance` since
    /// the last cached result — CLGeocoder is rate-limited by Apple and
    /// there is no benefit to asking twice for the same block.
    private func refreshLocalityIfNeeded() {
        guard let location = currentLocation else { return }

        if let anchor = lastGeocodedLocation,
           location.distance(from: anchor) < Self.localityRefetchDistance,
           currentLocality != nil {
            return
        }

        lastGeocodedLocation = location

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let placemark = placemarks?.first else { return }
                self.currentLocality = Self.formattedLocality(from: placemark)
            }
        }
    }

    /// Collapses a placemark down to "City, ST". Falls back gracefully:
    /// if the administrative area is missing we return just the city;
    /// if both are missing we return nil so the view can show its
    /// "Finding place" state instead of partial nonsense.
    private static func formattedLocality(from placemark: CLPlacemark) -> String? {
        let city = placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.name
        let region = placemark.administrativeArea

        switch (city, region) {
        case let (city?, region?):
            return "\(city), \(region)"
        case let (city?, nil):
            return city
        case (nil, let region?):
            return region
        default:
            return nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                locationStatus = .denied
                locationErrorMessage = "Allow location in Settings to see distance and nearby places."
            case .locationUnknown:
                locationErrorMessage = "Looking for your location..."
            default:
                locationErrorMessage = clError.localizedDescription
            }
        } else {
            locationErrorMessage = error.localizedDescription
        }
    }

    private func startLocationUpdates() {
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
    }

    private func refreshLocationAuthorization(
        startUpdatesIfAuthorized: Bool,
        requestAuthorizationIfNeeded: Bool = false
    ) async {
        guard !isRefreshingLocationAuthorization else { return }
        isRefreshingLocationAuthorization = true
        defer { isRefreshingLocationAuthorization = false }

        let snapshot = await Self.locationAuthorizationSnapshot()
        applyLocationAuthorizationSnapshot(snapshot, startUpdatesIfAuthorized: startUpdatesIfAuthorized)

        guard requestAuthorizationIfNeeded,
              snapshot.servicesEnabled,
              snapshot.authorizationStatus == .notDetermined
        else {
            return
        }

        locationErrorMessage = nil
        locationManager.requestWhenInUseAuthorization()
    }

    private func applyLocationAuthorizationSnapshot(
        _ snapshot: LocationAuthorizationSnapshot,
        startUpdatesIfAuthorized: Bool
    ) {
        guard snapshot.servicesEnabled else {
            locationStatus = .denied
            locationErrorMessage = "Location Services are off."
            return
        }

        locationStatus = PermissionCenter.mapLocationStatus(snapshot.authorizationStatus)

        switch locationStatus {
        case .notDetermined:
            locationErrorMessage = nil
        case .granted:
            locationErrorMessage = nil
            if startUpdatesIfAuthorized {
                startLocationUpdates()
            }
        case .denied:
            locationErrorMessage = "Allow location in Settings to see distance and nearby places."
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        notificationsStatus = PermissionCenter.mapNotificationStatus(settings.authorizationStatus)
    }

    nonisolated private static func locationAuthorizationSnapshot() async -> LocationAuthorizationSnapshot {
        await Task.detached(priority: .userInitiated) {
            let manager = CLLocationManager()
            return LocationAuthorizationSnapshot(
                servicesEnabled: CLLocationManager.locationServicesEnabled(),
                authorizationStatus: manager.authorizationStatus
            )
        }.value
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

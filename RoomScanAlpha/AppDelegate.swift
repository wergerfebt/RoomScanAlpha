import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import GoogleSignIn

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        print("[RoomScanAlpha] Firebase initialized")

        // Configure Google Sign-In with the OAuth client ID from Firebase
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            print("[RoomScanAlpha] Google Sign-In configured")
        } else {
            print("[RoomScanAlpha] WARNING: Firebase clientID is nil — Google Sign-In will not work")
        }

        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self

        requestNotificationPermission(application)
        return true
    }

    // Handle Google Sign-In OAuth redirect URL
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    private func requestNotificationPermission(_ application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("[RoomScanAlpha] Notification permission error: \(error.localizedDescription)")
            } else {
                print("[RoomScanAlpha] Notification permission granted: \(granted)")
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - Remote notification registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        print("[RoomScanAlpha] APNs device token registered")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[RoomScanAlpha] APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - MessagingDelegate

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else {
            print("[RoomScanAlpha] FCM token is nil")
            return
        }
        print("[RoomScanAlpha] FCM token: \(fcmToken)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }
}

import AuthenticationServices
import UIKit

/// Bridge between `ASAuthorizationController`'s delegate API and async/await.
/// Holds a continuation that is resumed exactly once when Apple's auth UI
/// either succeeds or fails. The owning AuthManager keeps a strong
/// reference for the lifetime of the auth flow so the delegate isn't
/// deallocated mid-presentation.
final class AppleSignInCoordinator: NSObject,
                                     ASAuthorizationControllerDelegate,
                                     ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private let onFinish: () -> Void

    init(continuation: CheckedContinuation<ASAuthorization, Error>,
         onFinish: @escaping () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func authorizationController(controller: ASAuthorizationController,
                                  didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
        onFinish()
    }

    func authorizationController(controller: ASAuthorizationController,
                                  didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        onFinish()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}

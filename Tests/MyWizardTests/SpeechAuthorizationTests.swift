import Dispatch
import Speech
import Testing
@testable import MyWizard

struct SpeechAuthorizationTests {
    @Test @MainActor
    func permissionCallbackCanReturnOnBackgroundQueue() async {
        let authorized = await SpeechAuthorization.request { reply in
            DispatchQueue.global().async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                reply(.authorized)
            }
        }
        #expect(authorized)
    }

    @Test @MainActor
    func deniedPermissionReturnsWithoutCrashing() async {
        let authorized = await SpeechAuthorization.request { reply in
            DispatchQueue.global().async { reply(.denied) }
        }
        #expect(!authorized)
    }
}

import Foundation
import ImageIO
import Intents
import PersonaStackCore
import UserNotifications

enum ConcernNotificationContent {
    static func present(_ content: UNMutableNotificationContent, body: Any,
                        update: (UNMutableNotificationContent, INSendMessageIntent) throws -> UNNotificationContent = {
                            try $0.updating(from: $1)
                        }) -> UNNotificationContent {
        guard let presentation = NotificationBridge.presentation(body) else { return content }
        content.title = presentation.title
        content.body = presentation.preview
        guard let data = presentation.avatarPNG, validAvatar(data) else { return content }
        let sender = INPerson(
            personHandle: INPersonHandle(value: presentation.personaID, type: .unknown),
            nameComponents: nil, displayName: presentation.title, image: INImage(imageData: data),
            contactIdentifier: nil, customIdentifier: presentation.personaID
        )
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: presentation.preview,
            speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: sender, attachments: nil
        )
        // The intent supplies the sender icon. Navigation remains in our private
        // metadata. Do not donate concern contents to Siri's interaction history.
        return (try? update(content, intent)) ?? content
    }

    static func validAvatar(_ data: Data) -> Bool {
        guard data.count <= 98_304,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 128,
              properties[kCGImagePropertyPixelHeight] as? Int == 128 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

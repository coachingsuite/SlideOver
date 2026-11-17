import Carbon

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey (no permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534C_4F56), id: id) // 'SLOV'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }
}

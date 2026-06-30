/// One explicit host-app hook for erasing local state created by the SDK.
public enum KenshikiPulseLocalState {
    public static func erase() {
        WifiNetworkIdentity.eraseLocalState()
        TelephonyDataServiceTracker.reset()
        TelephonyDataServiceSalt.clear()
        CallActivityRecorder.clear()
        DeviceRecurrence.eraseLocalState()
        EvidenceIntegrity.eraseLocalState()
    }
}

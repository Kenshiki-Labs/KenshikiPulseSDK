#if os(iOS) && canImport(CoreTelephony)
import CoreTelephony

/// Maps a raw `CTRadioAccessTechnology*` value to a coarse cellular generation label.
/// Shared by the SDK's evidence collector and host-app instrumentation so the mapping
/// lives in exactly one place.
public enum RadioAccessGeneration {
    public static func label(for rawTechnology: String) -> String {
        switch rawTechnology {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            return "5g"
        case CTRadioAccessTechnologyLTE:
            return "4g"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3g"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x:
            return "2g"
        default:
            return "unknown"
        }
    }
}
#endif

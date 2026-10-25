// ShutdownClassifier.swift — Thermik (MIT). OWNER: Unit 2. STUB from Unit 0; API FROZEN.
// Conservative token classifier for kern.shutdownreason (+ Intel "Previous shutdown cause" codes), SYS §7.
import Foundation

public enum ShutdownClassifier {
    public static func classify(_ boot: BootHistory) -> ShutdownVerdict { .unknown }
}

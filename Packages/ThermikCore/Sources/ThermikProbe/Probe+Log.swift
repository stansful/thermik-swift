// Probe+Log.swift — OWNER: Unit 6. `thermik-probe log write <dir> [daily|weekly|never|size:N]`: writes a 5-row sample
// log + column sidecar into the GIVEN directory with the real CSVLogWriter, then prints and checks both files.
// Three rows are written, the writer is closed (≈ quit) and a NEW writer appends two more (≈ relaunch): the file must
// keep one header and grow, never be truncated. Refuses ~/Documents (verification must never write there).
// Nothing is deleted. The machine facts in the header comment are read live (sysctl, read-only).
import Foundation
import ThermikCore
import ThermikSMC

extension Probe {
    static func log(_ args: [String]) async {
        guard args.first == "write", args.count >= 2 else {
            print("usage: thermik-probe log write <dir> [daily|weekly|never|size:N]")
            return
        }
        let dir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath).standardizedFileURL
        let documents = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents").standardizedFileURL
        guard !(dir.path == documents.path || dir.path.hasPrefix(documents.path + "/")) else {
            print("refusing to write into ~/Documents during verification; pass a scratch directory")
            exit(2)
        }
        var config = LogConfig()
        config.enabled = true
        config.folderPath = dir.path
        config.intervalSeconds = 10
        config.include = [.headline, .fans, .power, .thermal, .battery, .sensors, .events]
        config.sensorIDs = [.smc("Tp01"), .smc("Tg0f"), .hid("PMU tdie1")]
        switch args.count > 2 ? args[2] : "daily" {
        case "weekly": config.rotation = .weekly
        case "never": config.rotation = .never
        case let s where s.hasPrefix("size:"): config.rotation = .sizeMB(Int(s.dropFirst(5)) ?? 10)
        default: config.rotation = .daily
        }

        let sensorColumns = [
            CSVColumn(id: "smc:Tp01", nameEN: "P-cluster 0 core 1", nameRU: "Кластер P0, ядро 1"),
            CSVColumn(id: "smc:Tg0f", nameEN: "GPU sensor 1", nameRU: "ГП, датчик 1"),
            CSVColumn(id: "hid:PMU tdie1", nameEN: "PMU die 1", nameRU: "PMU, кристалл 1"),
        ]
        let columns = CSVLogLayout.columns(include: config.include, fanIndices: [0, 1], sensors: sensorColumns)
        let header = CSVLogLayout.header(config: config, columns: columns, hasFans: true, modelIdentifier: HostInfo.modelIdentifier,
                                         chip: ProbeLive.sysctlString("machdep.cpu.brand_string") ?? "unknown", osVersion: ProbeLive.osVersion(),
                                         appVersion: "probe")

        // Five samples 10 s apart ending now; gaps and events on purpose.
        let now = Date()
        func sample(_ i: Int) -> CSVLogSample {
            let load = Double(i) / 4
            var aggregates: [AggregateKind: Double] = [.cpuAverage: 59.94 + 20 * load, .cpuHottest: 76.86 + 20 * load,
                                                       .gpuAverage: 54.8 + 5 * load, .socDie: 62.5, .memory: 46.8, .ssd: 33.9,
                                                       .battery: 34.04]
            if i != 2 { aggregates[.gpuHottest] = 54.8 + 6 * load }           // row 3: no value → empty cell
            var sensors: [SensorID: Double] = [.smc("Tp01"): 61.53 + 30 * load, .smc("Tg0f"): 54.75]
            if i == 4 { sensors[.hid("PMU tdie1")] = 49.25 }                   // HID read only every 5th tick
            return CSVLogSample(aggregates: AggregateValues(values: aggregates),
                                fans: [0: .init(actualRPM: 1335.4 + 2000 * load, targetRPM: 1350 + 2000 * load),
                                       1: .init(actualRPM: 1453.2 + 2000 * load, targetRPM: i == 0 ? nil : 1458 + 2000 * load)],
                                power: PowerValues(systemTotalW: 19.46 + 40 * load, dcInW: 21, batteryW: -0.0, socW: 12.14 + 30 * load),
                                pressure: i == 4 ? .moderate : .nominal, batteryPercent: 81, onAC: true, sensors: sensors)
        }
        let events: [[String]] = [
            [AppEventPayload.appLaunched(version: "probe").csvToken],
            [AppEventPayload.fanModeChanged(FanModeChange(from: .system, to: .curve, reason: .user)).csvToken],
            [],
            [AppEventPayload.systemDidWake.csvToken],
            [AppEventPayload.alertRaised(ruleID: AlertRule.defaultRules[1].id, subject: .aggregate(.cpuHottest), value: 96.1,
                                         sensorID: nil).csvToken,
             AppEventPayload.thermalPressureChanged(.moderate).csvToken],
        ]
        let modes = ["system", "curve:balanced", "curve:balanced", "curve:balanced", "curve:balanced"]
        func row(_ i: Int) -> CSVLogRow {
            CSVLogRow(date: now.addingTimeInterval(Double(i - 4) * 10), numbers: CSVLogLayout.numbers(for: columns, sample: sample(i)),
                      fanMode: modes[i], events: events[i])
        }

        print("locale: \(Locale.current.identifier), decimal separator \"\(Locale.current.decimalSeparator ?? "?")\" (the CSV always uses \".\")")
        let first = CSVLogWriter(config: config, header: header)
        for i in 0..<3 { await first.append(row(i)) }
        await first.close()                                                   // ≈ quit
        guard let url = await first.currentFileURL else {
            print("FAIL no file was written: \(await first.lastError ?? "unknown error")")
            exit(1)
        }
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let second = CSVLogWriter(config: config, header: header)             // ≈ relaunch: must append
        for i in 3..<5 { await second.append(row(i)) }
        await second.close()
        let secondURL = await second.currentFileURL

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sidecar = CSVLogWriter.sidecarURL(for: url)
        print("\n# \(url.path)\n" + text)
        print("# \(sidecar.path)")
        print((try? String(contentsOf: sidecar, encoding: .utf8)) ?? "(missing)")

        // Checks.
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failed += 1 } }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        let rows = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("timestamp,") }
        let newRows = rows.count - before.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("timestamp,") }.count
        check(lines.first?.hasPrefix("# Thermik log v1; model=") == true && lines.first?.contains("; unit=C; interval=10s") == true,
              "header comment line")
        check(lines.filter { $0.hasPrefix("# Thermik log v1") }.count == 1 && lines.filter { $0.hasPrefix("timestamp,") }.count == 1,
              "exactly one header after a close + reopen (appended, not truncated or duplicated)")
        check(secondURL == url && newRows == 2 && rows.count >= 5, "the relaunched writer appended 2 rows to the same file (\(rows.count) rows)")
        let iso = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2}),"#)
        check(rows.allSatisfy { r in iso?.firstMatch(in: r, range: NSRange(r.startIndex..., in: r)) != nil },
              "ISO 8601 timestamps with an offset")
        let cells = rows.suffix(5).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        let width = CSVLogWriter.columnLineCount(header)
        check(cells.allSatisfy { $0.count == width }, "every row has \(width) cells")
        let numeric = cells.flatMap { $0.dropFirst().prefix(columns.count) }.filter { !$0.isEmpty }
        check(numeric.allSatisfy { Double($0) != nil && !$0.contains(",") }, "numbers use \".\" and parse back")
        check(!numeric.contains("-0.0") && !numeric.contains("-0"), "no negative zero")
        check(cells.contains { $0.dropFirst().prefix(columns.count).contains("") }, "missing values are empty cells")
        check(cells.last?.last?.contains("alert:aggregate(cpuHottest)=96.1") == true && cells.last?.last?.contains(";pressure:1") == true,
              "event tokens in their own column, ';'-joined")
        check(FileManager.default.fileExists(atPath: sidecar.path), "column-map sidecar written")

        // A different column set (one more sensor) must start a new file, never rewrite or mix into the old one.
        var wider = config
        wider.sensorIDs.append(.smc("Te05"))
        let widerColumns = CSVLogLayout.columns(include: wider.include, fanIndices: [0, 1],
                                                sensors: sensorColumns + [CSVColumn(id: "smc:Te05", nameEN: "E-cluster core 1",
                                                                                    nameRU: "Кластер E, ядро 1")])
        let widerHeader = CSVLogLayout.header(config: wider, columns: widerColumns, hasFans: true, modelIdentifier: header.modelIdentifier,
                                              chip: header.chip, osVersion: header.osVersion, appVersion: "probe")
        let third = CSVLogWriter(config: wider, header: widerHeader)
        await third.append(CSVLogRow(date: now, numbers: CSVLogLayout.numbers(for: widerColumns, sample: sample(4)),
                                     fanMode: "max", events: []))
        await third.close()
        let thirdURL = await third.currentFileURL
        print("\nlayout change → \(thirdURL?.lastPathComponent ?? "nil")")
        check(thirdURL != nil && thirdURL != url && (try? String(contentsOf: url, encoding: .utf8)) == text,
              "a changed column layout starts \(thirdURL?.lastPathComponent ?? "?"); the first file is untouched")
        print(failed == 0 ? "\nall checks passed" : "\n\(failed) check(s) failed")
        if failed > 0 { exit(1) }
    }
}

private extension CSVLogWriter {
    /// Cells per row for `header` (timestamp + numeric + fan_mode + event).
    static func columnLineCount(_ h: CSVLogHeader) -> Int {
        1 + h.numericColumns.count + (h.includesFanMode ? 1 : 0) + (h.includesEvents ? 1 : 0)
    }
}

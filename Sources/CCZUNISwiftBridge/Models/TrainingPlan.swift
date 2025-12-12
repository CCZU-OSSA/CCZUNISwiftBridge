import Foundation

/// 培养方案课程条目（来自接口原始字段）
public struct RawTrainingPlanItem: Codable {
    public let nj: Int?
    public let zydm: String?
    public let xz: String?
    public let xq: Int
    public let kcdm: String
    public let kcmc: String
    public let lbdh: String
    public let xf: Double
    public let lbmc: String
    public let xh: String?
    public let kscj: Double?
    public let lb: String?
    public let zymc: String?
}

/// 课程类型归类（UI视图需要的三类 + 实践）
public enum PlanCourseType: String, Codable {
    case required
    case elective
    case practice
}

/// 计划课程（用于App展示）
public struct PlanCourse: Codable, Identifiable {
    public let id: String
    public let name: String
    public let code: String
    public let credits: Double
    public let type: PlanCourseType
    public let teacher: String?
}

/// 培养方案聚合模型
public struct TrainingPlan: Codable {
    public let majorName: String
    public let degree: String
    public let durationYears: Int
    public let totalCredits: Double
    public let requiredCredits: Double
    public let electiveCredits: Double
    public let practiceCredits: Double
    public let objectives: String?
    public let coursesBySemester: [Int: [PlanCourse]]
}

/// 培养方案解析器
public enum TrainingPlanParser {
    public static func parse(from data: Data, basicInfo: StudentBasicInfo? = nil) throws -> TrainingPlan {
        struct ErrorRoot: Codable { let status: Int; let message: String }
        if let errorRoot = try? JSONDecoder().decode(ErrorRoot.self, from: data) {
            if errorRoot.status != 0 { throw CCZUError.unknown(errorRoot.message) }
        }

        struct RootArray: Codable { let status: Int; let message: [RawTrainingPlanItem] }
        if let root = try? JSONDecoder().decode(RootArray.self, from: data) {
            return aggregate(items: root.message, basicInfo: basicInfo)
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if let dict = json as? [String: Any] {
            let status = dict["status"] as? Int ?? 0
            if status != 0, let msg = dict["message"] as? String {
                throw CCZUError.unknown(msg)
            }
            if let arr = dict["message"] as? [Any] {
                var items: [RawTrainingPlanItem] = []
                for el in arr {
                    if let e = el as? [String: Any] {
                        let nj = e["nj"] as? Int
                        let zydm = e["zydm"] as? String
                        let xzStr = e["xz"] as? String
                        let xq = (e["xq"] as? Int) ?? Int((e["xq"] as? String) ?? "0") ?? 0
                        let kcdm = (e["kcdm"] as? String) ?? ""
                        let kcmc = (e["kcmc"] as? String) ?? ""
                        let lbdh = (e["lbdh"] as? String) ?? (e["lb"] as? String) ?? ""
                        let xf = (e["xf"] as? Double) ?? Double((e["xf"] as? String) ?? "0") ?? 0
                        let lbmc = (e["lbmc"] as? String) ?? (e["lb"] as? String) ?? ""
                        let xh = e["xh"] as? String
                        let kscj = e["kscj"] as? Double
                        let lb = e["lb"] as? String
                        let zymc = e["zymc"] as? String

                        let item = RawTrainingPlanItem(
                            nj: nj,
                            zydm: zydm,
                            xz: xzStr,
                            xq: xq,
                            kcdm: kcdm,
                            kcmc: kcmc,
                            lbdh: lbdh,
                            xf: xf,
                            lbmc: lbmc,
                            xh: xh,
                            kscj: kscj,
                            lb: lb,
                            zymc: zymc
                        )
                        items.append(item)
                    }
                }
                return aggregate(items: items, basicInfo: basicInfo)
            }
        }

        if let arr = json as? [[String: Any]] {
            var items: [RawTrainingPlanItem] = []
            for e in arr {
                let xq = (e["xq"] as? Int) ?? Int((e["xq"] as? String) ?? "0") ?? 0
                let kcdm = (e["kcdm"] as? String) ?? ""
                let kcmc = (e["kcmc"] as? String) ?? ""
                let lbdh = (e["lbdh"] as? String) ?? (e["lb"] as? String) ?? ""
                let xf = (e["xf"] as? Double) ?? Double((e["xf"] as? String) ?? "0") ?? 0
                let lbmc = (e["lbmc"] as? String) ?? (e["lb"] as? String) ?? ""
                let zymc = e["zymc"] as? String
                let item = RawTrainingPlanItem(nj: e["nj"] as? Int, zydm: e["zydm"] as? String, xz: e["xz"] as? String, xq: xq, kcdm: kcdm, kcmc: kcmc, lbdh: lbdh, xf: xf, lbmc: lbmc, xh: e["xh"] as? String, kscj: e["kscj"] as? Double, lb: e["lb"] as? String, zymc: zymc)
                items.append(item)
            }
            return aggregate(items: items, basicInfo: basicInfo)
        }

        throw CCZUError.unknown("Unexpected training plan response format")
    }
    
    private static func aggregate(items: [RawTrainingPlanItem], basicInfo: StudentBasicInfo?) -> TrainingPlan {
        let majorName = basicInfo?.major.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? items.first?.zymc?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let durationYears = Int(basicInfo?.studyLength ?? items.first?.xz ?? "0") ?? 0

        var coursesBySemester: [Int: [PlanCourse]] = [:]
        var requiredCredits = 0.0
        var electiveCredits = 0.0
        var practiceCredits = 0.0
        var totalCredits = 0.0

        for item in items {
            let code = item.kcdm
            let name = item.kcmc.trimmingCharacters(in: .whitespacesAndNewlines)
            let credits = item.xf
            let semester = item.xq
            totalCredits += credits

            let type: PlanCourseType
            switch item.lbdh.trimmingCharacters(in: .whitespaces) {
            case "A1", "B1", "C1":
                type = .required
                requiredCredits += credits
            case let s where s.uppercased().hasPrefix("S"):
                type = .practice
                practiceCredits += credits
            default:
                type = .elective
                electiveCredits += credits
            }

            let course = PlanCourse(
                id: code,
                name: name,
                code: code,
                credits: credits,
                type: type,
                teacher: nil
            )
            coursesBySemester[semester, default: []].append(course)
        }

        return TrainingPlan(
            majorName: majorName,
            degree: "",
            durationYears: durationYears,
            totalCredits: totalCredits,
            requiredCredits: requiredCredits,
            electiveCredits: electiveCredits,
            practiceCredits: practiceCredits,
            objectives: nil,
            coursesBySemester: coursesBySemester
        )
    }
}

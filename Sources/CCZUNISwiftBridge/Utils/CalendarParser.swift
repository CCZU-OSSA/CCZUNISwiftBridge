import Foundation

/// 课程信息(已解析)
public struct ParsedCourse: Sendable {
    public let name: String
    public let teacher: String
    public let location: String
    public let weeks: [Int]
    public let dayOfWeek: Int
    public let timeSlot: Int
    
    public init(name: String, teacher: String, location: String, weeks: [Int], dayOfWeek: Int, timeSlot: Int) {
        self.name = name
        self.teacher = teacher
        self.location = location
        self.weeks = weeks
        self.dayOfWeek = dayOfWeek
        self.timeSlot = timeSlot
    }
}

/// 日历解析器
public struct CalendarParser {
    public static func parseWeekMatrix(_ matrix: [[RawCourse]]) -> [ParsedCourse] {
        var courses: [ParsedCourse] = []
        for (timeIndex, timeCourses) in matrix.enumerated() {
            for (dayIndex, rawCourse) in timeCourses.enumerated() {
                if rawCourse.course.isEmpty { continue }
                let courseParts = rawCourse.course.split(separator: "/")
                for part in courseParts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    let components = trimmed.split(separator: " ").map(String.init)
                    if components.isEmpty { continue }
                    let name = components[0]
                    var location = ""
                    var weeks: [Int] = []
                    var locationParts: [String] = []
                    var weekComponents: [String] = []
                    for component in components.dropFirst() {
                        let compTrimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                        if compTrimmed.isEmpty { continue }
                        if compTrimmed.contains("周") || compTrimmed == "单" || compTrimmed == "双" || compTrimmed.range(of: "^[\\d,-]+[,，]?$", options: .regularExpression) != nil {
                            weekComponents.append(compTrimmed)
                            continue
                        }
                        let cleaned = compTrimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",，;:。"))
                        if !cleaned.isEmpty { locationParts.append(cleaned) }
                    }
                    if !weekComponents.isEmpty {
                        weeks = parseWeeks(from: weekComponents.joined(separator: " "))
                    }
                    location = locationParts.joined(separator: " ")
                    let teacherParts = rawCourse.teacher.components(separatedBy: ",/")
                    let teacher = (teacherParts.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ",，"))
                    let course = ParsedCourse(
                        name: name,
                        teacher: teacher,
                        location: location,
                        weeks: weeks,
                        dayOfWeek: dayIndex + 1,
                        timeSlot: timeIndex + 1
                    )
                    courses.append(course)
                }
            }
        }
        return courses
    }
    
    private static func parseWeeks(from weekString: String) -> [Int] {
        var weeks: [Int] = []
        var cleaned = weekString.replacingOccurrences(of: "周", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ",，;:。"))
        let isOdd = cleaned.contains("单")
        let isEven = cleaned.contains("双")
        cleaned = cleaned.replacingOccurrences(of: "单", with: "")
        cleaned = cleaned.replacingOccurrences(of: "双", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let rangeStr = cleaned.replacingOccurrences(of: "[^0-9\\-,]", with: "", options: .regularExpression)
        if rangeStr.isEmpty { return [] }
        let segments = rangeStr.split(separator: ",").map(String.init)
        for segment in segments {
            if segment.contains("-") {
                let parts = segment.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 {
                    let start = parts[0]
                    let end = parts[1]
                    for week in start...end {
                        if isOdd && week % 2 == 1 {
                            if !weeks.contains(week) { weeks.append(week) }
                        } else if isEven && week % 2 == 0 {
                            if !weeks.contains(week) { weeks.append(week) }
                        } else if !isOdd && !isEven {
                            if !weeks.contains(week) { weeks.append(week) }
                        }
                    }
                }
            } else if let week = Int(segment) {
                if isOdd && week % 2 == 1 {
                    if !weeks.contains(week) { weeks.append(week) }
                } else if isEven && week % 2 == 0 {
                    if !weeks.contains(week) { weeks.append(week) }
                } else if !isOdd && !isEven {
                    if !weeks.contains(week) { weeks.append(week) }
                }
            }
        }
        return weeks.sorted()
    }
}

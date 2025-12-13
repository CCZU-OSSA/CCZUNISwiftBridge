import Foundation

/// 教务企业微信应用
public final class JwqywxApplication: @unchecked Sendable {
    private let client: DefaultHTTPClient
    private var authorizationToken: String?
    private var authorizationId: String?
    private var studentNumber: String?
    private var customHeaders: [String: String]
    private var trainingPlanCache: TrainingPlan?
    public private(set) var lastTrainingPlanRawResponse: String?
    
    public init(client: DefaultHTTPClient) {
        self.client = client
        self.customHeaders = CCZUConstants.defaultHeaders
        self.customHeaders["Referer"] = "http://jwqywx.cczu.edu.cn/"
        self.customHeaders["Origin"] = "http://jwqywx.cczu.edu.cn"
    }
    
    public func login() async throws -> Message<LoginUserData> {
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/login")!
        let loginData: [String: String] = [
            "userid": client.account.username,
            "userpwd": client.account.password
        ]
        customHeaders.removeValue(forKey: "Authorization")
        let (data, response) = try await client.postJSON(url: url, headers: customHeaders, json: loginData)
        guard response.statusCode == 200 else { throw CCZUError.loginFailed("HTTP Status code: \(response.statusCode)") }
        let decoder = JSONDecoder()
        let message = try decoder.decode(Message<LoginUserData>.self, from: data)
        guard let token = message.token else { throw CCZUError.loginFailed("未收到认证令牌") }
        guard let userData = message.message.first else { throw CCZUError.loginFailed("未收到用户数据") }
        if userData.id.isEmpty || userData.userid.isEmpty { throw CCZUError.invalidCredentials }
        authorizationToken = "Bearer \(token)"
        authorizationId = userData.id
        studentNumber = userData.userid
        customHeaders["Authorization"] = authorizationToken
        Task { [weak self] in
            do { _ = try await self?.prefetchTrainingPlan() } catch {}
        }
        return message
    }
    
    public func getGrades() async throws -> Message<CourseGrade> {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/cj_xh")!
        let requestData = ["xh": authId]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        return try decoder.decode(Message<CourseGrade>.self, from: data)
    }
    
    public func getCreditsAndRank() async throws -> Message<StudentPoint> {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/cj_xh_xfjd")!
        let requestData = ["xh": authId]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        return try decoder.decode(Message<StudentPoint>.self, from: data)
    }
    
    public func getTerms() async throws -> Message<Term> {
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/xqall")!
        let (data, _) = try await client.get(url: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Message<Term>.self, from: data)
    }

    public func getTrainingPlan() async throws -> TrainingPlan {
        if let cached = trainingPlanCache { return cached }
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        guard let stuNum = studentNumber else { throw CCZUError.notLoggedIn }
        if let disk = try? loadTrainingPlanFromDisk(studentNumber: stuNum) {
            trainingPlanCache = disk
            return disk
        }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/cj_xh_jxjh_cj")!
        let cleanStudentNumber = stuNum.trimmingCharacters(in: .whitespacesAndNewlines)
        var requestData: [String: String] = [
            "xh": authId,
            "yhid": authId
        ]
        do {
            let basic = try await getStudentBasicInfo()
            if let info = basic.message.first {
                let grade = String(info.grade)
                let studyLength = String(info.studyLength)
                requestData["nj"] = grade
                requestData["xz"] = studyLength
                let majorCode = info.majorCode
                if !majorCode.isEmpty {
                    requestData["zydm"] = majorCode
                }
            }
        } catch {
            print("[WARN] 获取学生基本信息失败，继续请求培养方案: \(error)")
        }
        print("[DEBUG] 培养方案请求参数: \(requestData)")
        var (data, response) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        print("[DEBUG] 培养方案响应状态: \(response.statusCode)")
        if let responseString = String(data: data, encoding: .utf8) {
            print("[DEBUG] 培养方案响应长度: \(responseString.count)")
            print("[DEBUG] 培养方案完整响应: \(responseString)")
            lastTrainingPlanRawResponse = responseString
        }
        var plan: TrainingPlan
        do {
            let basic = try? await getStudentBasicInfo()
            plan = try TrainingPlanParser.parse(from: data, basicInfo: basic?.message.first)
        } catch {
            print("[WARN] 培养方案首次解析失败，尝试用学号重试: \(error)")
            requestData["xh"] = cleanStudentNumber
            print("[DEBUG] 培养方案回退参数: \(requestData)")
            let retry = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
            data = retry.0
            response = retry.1
            if let responseString = String(data: data, encoding: .utf8) {
                print("[DEBUG] 培养方案回退响应长度: \(responseString.count)")
                print("[DEBUG] 培养方案回退完整响应: \(responseString)")
                lastTrainingPlanRawResponse = responseString
            }
            let basic = try? await getStudentBasicInfo()
            plan = try TrainingPlanParser.parse(from: data, basicInfo: basic?.message.first)
        }
        trainingPlanCache = plan
        try? saveTrainingPlanToDisk(plan, studentNumber: stuNum)
        return plan
    }

    @discardableResult
    public func prefetchTrainingPlan() async throws -> TrainingPlan {
        guard let _ = authorizationId, let _ = studentNumber else { throw CCZUError.notLoggedIn }
        return try await getTrainingPlan()
    }

    public func clearTrainingPlanCache() {
        trainingPlanCache = nil
    }

    private func cacheURL(studentNumber: String) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CCZUKit", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("training_plan_\(studentNumber).json")
    }

    private func saveTrainingPlanToDisk(_ plan: TrainingPlan, studentNumber: String) throws {
        let url = try cacheURL(studentNumber: studentNumber)
        let data = try JSONEncoder().encode(plan)
        try data.write(to: url, options: .atomic)
    }

    private func loadTrainingPlanFromDisk(studentNumber: String) throws -> TrainingPlan? {
        let url = try cacheURL(studentNumber: studentNumber)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TrainingPlan.self, from: data)
    }

    public func deleteTrainingPlanDiskCache() {
        guard let stuNum = studentNumber, let url = try? cacheURL(studentNumber: stuNum) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    public func getStudentBasicInfo() async throws -> Message<StudentBasicInfo> {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        guard let stuNum = studentNumber else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/xs_xh_jbxx")!
        let requestData = ["xh": stuNum, "yhid": authId]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        return try decoder.decode(Message<StudentBasicInfo>.self, from: data)
    }
    
    public func getClassSchedule(term: String) async throws -> [[RawCourse]] {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/kb_xq_xh")!
        let requestData: [String: String] = [
            "xh": client.account.username,
            "xq": term,
            "yhid": authId
        ]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        let jsonObject = try decoder.decode(Message<CourseScheduleRow>.self, from: data)
        return jsonObject.message.map { $0.toCourses() }
    }
    
    public func getCurrentClassSchedule() async throws -> [[RawCourse]] {
        let terms = try await getTerms()
        guard let currentTerm = terms.message.first?.term else { throw CCZUError.missingData("No term found") }
        return try await getClassSchedule(term: currentTerm)
    }
    
    public func getExamArrangements(term: String? = nil, examType: String = "学分制考试") async throws -> [ExamArrangement] {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let examTerm: String
        if let term = term {
            examTerm = term
        } else {
            let terms = try await getTerms()
            guard let currentTerm = terms.message.first?.term else { throw CCZUError.missingData("No term found") }
            examTerm = currentTerm
        }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/ks_xs_kslb")!
        let requestData: [String: String] = [
            "xq": examTerm,
            "yhdm": client.account.username,
            "dm": examType,
            "yhid": authId
        ]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        let message = try decoder.decode(Message<ExamArrangement>.self, from: data)
        return message.message
    }
    
    public func getCurrentExamArrangements() async throws -> [ExamArrangement] {
        return try await getExamArrangements()
    }
    
    public func getEvaluatableClasses(term: String) async throws -> [EvaluatableClass] {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/pj_xspj_kcxx")!
        let requestData: [String: String] = [
            "pjxq": term,
            "xh": client.account.username,
            "yhid": authId
        ]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        let message = try decoder.decode(Message<EvaluatableClass>.self, from: data)
        return message.message
    }
    
    public func getCurrentEvaluatableClasses() async throws -> [EvaluatableClass] {
        let terms = try await getTerms()
        guard let currentTerm = terms.message.first?.term else { throw CCZUError.missingData("No term found") }
        return try await getEvaluatableClasses(term: currentTerm)
    }
    
    public func getSubmittedEvaluations(term: String) async throws -> [SubmittedEvaluation] {
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/pj_xh_pjxx")!
        let requestData: [String: String] = [
            "pjxq": term,
            "xh": client.account.username
        ]
        let (data, _) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        let decoder = JSONDecoder()
        let message = try decoder.decode(Message<SubmittedEvaluation>.self, from: data)
        return message.message
    }
    
    public func getCurrentSubmittedEvaluations() async throws -> [SubmittedEvaluation] {
        let terms = try await getTerms()
        guard let currentTerm = terms.message.first?.term else { throw CCZUError.missingData("No term found") }
        return try await getSubmittedEvaluations(term: currentTerm)
    }
    
    public func submitEvaluation(term: String, evaluationId: String, scores: String, comments: String) async throws -> Bool {
        guard let authId = authorizationId else { throw CCZUError.notLoggedIn }
        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/pj_xh_tj_pjxx")!
        let requestData: [String: String] = [
            "pjxq": term,
            "pjid": evaluationId,
            "xh": client.account.username,
            "zf": scores,
            "yjjy": comments,
            "yhid": authId
        ]
        let (_, response) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        return response.statusCode == 200
    }

    /// 兼容主 App 旧接口：提交教师评价（按评价ID与逗号分隔分数）
    public func submitTeacherEvaluation(term: String, evaluationId: String, scores: String, comments: String) async throws -> Bool {
        return try await submitEvaluation(term: term, evaluationId: evaluationId, scores: scores, comments: comments)
    }

    /// 兼容 CCZUKit 老接口：提交教师评价（按课程与教师信息、总分与分数组）
    /// 与 CCZUKit 保持一致的签名以便主 App 无缝切换。
    public func submitTeacherEvaluation(
        term: String,
        evaluatableClass: EvaluatableClass,
        overallScore: Int,
        scores: [Int],
        comments: String
    ) async throws -> Bool {
        guard let authId = authorizationId else {
            throw CCZUError.notLoggedIn
        }
        // 将分数数组转换为逗号分隔的字符串，末尾加逗号，兼容原后端格式
        let scoresString = scores.map(String.init).joined(separator: ",") + ","

        let url = URL(string: "http://jwqywx.cczu.edu.cn:8180/api/pj_insert_xspj")!
        let requestData: [String: String] = [
            "pjxq": term,
            "yhdm": client.account.username,
            "jsdm": evaluatableClass.teacherCode,
            "kcdm": evaluatableClass.courseCode,
            "zhdf": String(overallScore),
            "pjjg": scoresString,
            "yjjy": comments,
            "yhid": authId
        ]

        let (_, response) = try await client.postJSON(url: url, headers: customHeaders, json: requestData)
        guard response.statusCode == 200 else {
            throw CCZUError.unknown("HTTP Status code: \(response.statusCode)")
        }
        return true
    }
    
    public func getClassScheduleParsed(term: String) async throws -> [ParsedCourse] {
        let matrix = try await getClassSchedule(term: term)
        return CalendarParser.parseWeekMatrix(matrix)
    }
    
    public func getCurrentClassScheduleParsed() async throws -> [ParsedCourse] {
        let matrix = try await getCurrentClassSchedule()
        return CalendarParser.parseWeekMatrix(matrix)
    }
    
    public func getElectricityAreas() async throws -> [ElectricityArea] {
        // 预定义的校区配置
        return [
            ElectricityArea(area: "西太湖校区", areaname: "西太湖校区", aid: "0030000000002501"),
            ElectricityArea(area: "武进校区", areaname: "武进校区", aid: "0030000000002502"),
            ElectricityArea(area: "西太湖校区1-7,10-11", areaname: "西太湖校区1-7,10-11", aid: "0030000000002503")
        ]
    }
    
    public func getBuildings(area: ElectricityArea) async throws -> [Building] {
        let url = URL(string: "http://wxxy.cczu.edu.cn/wechat/callinterface/queryElecBuilding.html")!
        
        let areaDict: [String: String] = ["area": area.area, "areaname": area.areaname]
        let areaJson = try String(data: JSONEncoder().encode(areaDict), encoding: .utf8) ?? ""
        
        let payload: [String: String] = [
            "areajson": areaJson,
            "areaid": area.aid
        ]
        
        var headers = customHeaders
        headers["User-Agent"] = "Mozilla/5.0 (Linux; Android 15; V2232A Build/AP3A.240905.015.A2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/134.0.6998.136 Mobile Safari/537.36 XWEB/1340157 MMWEBSDK/20250201 MMWEBID/140 wxwork/4.1.38 MicroMessenger/7.0.1 NetType/WIFI Language/zh Lang/zh ColorScheme/Light wwmver/3.26.38.639"
        
        let (data, response) = try await client.postForm(url: url, headers: headers, formData: payload)
        
        guard response.statusCode == 200 else {
            throw CCZUError.unknown("HTTP Status code: \(response.statusCode)")
        }
        
        let decoder = JSONDecoder()
        let json = try decoder.decode([String: [Building]].self, from: data)
        return json["buildingtab"] ?? []
    }
    
    public func queryElectricity(area: ElectricityArea, building: Building, roomId: String) async throws -> ElectricityResponse {
        let url = URL(string: "http://wxxy.cczu.edu.cn/wechat/callinterface/queryElecRoomInfo.html")!
        
        let areaDict: [String: String] = ["area": area.area, "areaname": area.areaname]
        let buildingDict: [String: String] = ["building": building.building, "buildingid": building.buildingid]
        
        let areaJson = try String(data: JSONEncoder().encode(areaDict), encoding: .utf8) ?? ""
        let buildingJson = try String(data: JSONEncoder().encode(buildingDict), encoding: .utf8) ?? ""
        
        let payload: [String: String] = [
            "areajson": areaJson,
            "areaid": area.aid,
            "buildjson": buildingJson,
            "buildingid": building.buildingid,
            "roomid": roomId
        ]
        
        var headers = customHeaders
        headers["User-Agent"] = "Mozilla/5.0 (Linux; Android 15; V2232A Build/AP3A.240905.015.A2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/134.0.6998.136 Mobile Safari/537.36 XWEB/1340157 MMWEBSDK/20250201 MMWEBID/140 wxwork/4.1.38 MicroMessenger/7.0.1 NetType/WIFI Language/zh Lang/zh ColorScheme/Light wwmver/3.26.38.639"
        
        let (data, response) = try await client.postForm(url: url, headers: headers, formData: payload)
        
        guard response.statusCode == 200 else {
            throw CCZUError.unknown("HTTP Status code: \(response.statusCode)")
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(ElectricityResponse.self, from: data)
    }
}


private struct CourseScheduleRow: Decodable, Sendable {
    let fields: [String: AnyCodable]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: AnyCodable].self)
        self.fields = dict
    }
    
    func toCourses() -> [RawCourse] {
        var courses: [String] = []
        var teachers: [String: String] = [:]
        
        // 提取课程信息 (kc1-kc7)
        for index in 1...7 {
            let key = "kc\(index)"
            if let courseValue = fields[key], let course = courseValue.stringValue {
                courses.append(course)
            } else {
                courses.append("")
            }
        }
        
        // 提取教师信息 (kcmc1-kcmc20 和 skjs1-skjs20)
        for index in 1...20 {
            let nameKey = "kcmc\(index)"
            let teacherKey = "skjs\(index)"
            
            if let nameValue = fields[nameKey], let name = nameValue.stringValue,
               let teacherValue = fields[teacherKey], let teacher = teacherValue.stringValue {
                teachers[name] = teacher
            }
        }
        
        // 组合课程和教师信息
        return courses.map { course in
            let courseParts = course.split(separator: "/")
            let teacherParts = courseParts.map { part -> String in
                let courseName = part.split(separator: " ").first.map(String.init) ?? ""
                return teachers[courseName] ?? ""
            }
            
            let teacher = teacherParts.filter { !$0.isEmpty }.joined(separator: ",/")
            return RawCourse(course: course, teacher: teacher)
        }
    }
}

// MARK: - AnyCodable辅助类型

private enum AnyCodableValue: Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case null
}

private struct AnyCodable: Decodable, Sendable {
    let value: AnyCodableValue
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            value = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            value = .string(stringValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            value = .bool(boolValue)
        } else if container.decodeNil() {
            value = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    var stringValue: String? {
        if case .string(let str) = value {
            return str
        }
        return nil
    }
}

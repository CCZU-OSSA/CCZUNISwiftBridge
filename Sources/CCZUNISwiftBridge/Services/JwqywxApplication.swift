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

    /// 兼容主 App 旧接口：提交教师评价
    public func submitTeacherEvaluation(term: String, evaluationId: String, scores: String, comments: String) async throws -> Bool {
        return try await submitEvaluation(term: term, evaluationId: evaluationId, scores: scores, comments: comments)
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
        let url = URL(string: "http://weapp.cczu.edu.cn/homecenter-server/external/urs1235000059")!
        let (data, _) = try await client.get(url: url)
        let decoder = JSONDecoder()
        return try decoder.decode([ElectricityArea].self, from: data)
    }
    
    public func getBuildings(areaId: String) async throws -> [Building] {
        let url = URL(string: "http://weapp.cczu.edu.cn/homecenter-server/external/urs1235000099?areaid=\(areaId)")!
        let (data, _) = try await client.get(url: url)
        let decoder = JSONDecoder()
        return try decoder.decode([Building].self, from: data)
    }
    
    public func getRooms(buildingId: String) async throws -> [Room] {
        let url = URL(string: "http://weapp.cczu.edu.cn/homecenter-server/external/urs1235000100?buildingid=\(buildingId)")!
        let (data, _) = try await client.get(url: url)
        let decoder = JSONDecoder()
        return try decoder.decode([Room].self, from: data)
    }
    
    public func getElectricity(areaId: String, buildingId: String, roomId: String) async throws -> ElectricityResponse {
        let url = URL(string: "http://weapp.cczu.edu.cn/homecenter-server/external/urs1235000101?areaid=\(areaId)&buildingid=\(buildingId)&roomid=\(roomId)")!
        let (data, _) = try await client.get(url: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ElectricityResponse.self, from: data)
    }

    /// 兼容主 App 旧接口：查询电费
    public func queryElectricity(areaId: String, buildingId: String, roomId: String) async throws -> ElectricityResponse {
        return try await getElectricity(areaId: areaId, buildingId: buildingId, roomId: roomId)
    }

    /// 兼容主 App 旧接口（不同标签和类型）：查询电费
    public func queryElectricity(area: ElectricityArea, building: Building, roomId: String) async throws -> ElectricityResponse {
        return try await getElectricity(areaId: area.aid, buildingId: building.buildingid, roomId: roomId)
    }
}

private struct CourseScheduleRow: Decodable {
    let kcmc: String
    let jsxx: String
    let jc: String
    
    func toCourses() -> [RawCourse] {
        let classes = kcmc.split(separator: ";").map(String.init)
        let teachers = jsxx.split(separator: ";").map(String.init)
        let units = max(classes.count, teachers.count)
        var result: [RawCourse] = []
        for i in 0..<units {
            let course = i < classes.count ? classes[i] : ""
            let teacher = i < teachers.count ? teachers[i] : ""
            result.append(RawCourse(course: course, teacher: teacher))
        }
        return result
    }
}

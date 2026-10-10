
import AVFoundation
import PhotosUI
import Security
import SwiftUI
import UIKit

// MARK: - Model

struct MealAnalysisItem: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var carbs: Double = 0
    var fat: Double = 0
    var protein: Double = 0
    var multiplier: Double = 1
    var basis: String = "Manual entry"

    var scaledCarbs: Double { carbs * multiplier }
    var scaledFat: Double { fat * multiplier }
    var scaledProtein: Double { protein * multiplier }
}

struct MealError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Keychain

enum MealKeychain {
    private static let service = "tai.mealanalysis"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func get(_ account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ account: String, value: String) {
        let base = baseQuery(account)
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Services

enum MealServices {
    static let defaultGeminiModel = "gemini-2.5-flash"
    static let defaultClaudeModel = "claude-sonnet-4-5"
    static let userAgent = "Tai-MealAnalysis/1.0 (personal test build)"

    static func model(_ defaultsKey: String, fallback: String) -> String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return stored.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : stored
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    static func jpegBase64(_ image: UIImage) -> String? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1024 / longest)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }

    static func prompt(description: String, hasImage: Bool) -> String {
        var text = "You estimate the nutrition of a meal for a person with diabetes who is logging it. "
        text +=
            "Identify each food item, state the portion you assumed, and estimate grams of carbohydrate, fat and protein for that portion as eaten (not per 100 g). "
        text += "Do not give insulin or dosing advice. If unsure, give your best estimate and say so in the portion text. "
        text +=
            "Reply with ONLY JSON in this shape: {\"items\":[{\"name\":\"\",\"portion\":\"\",\"carbs_g\":0,\"fat_g\":0,\"protein_g\":0}]}. "
        if hasImage { text += "A photo of the meal is attached. " }
        if !description.isEmpty { text += "User description: \(description)" }
        return text
    }

    static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MealError(message: "No response from the server.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MealError(message: "Server error \(http.statusCode): \(String(body.prefix(200)))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MealError(message: "Unexpected reply format.")
        }
        return json
    }

    static func parseItems(_ raw: String, basis: String) throws -> [MealAnalysisItem] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start ... end])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["items"] as? [[String: Any]],
              !list.isEmpty
        else {
            throw MealError(message: "The AI reply could not be read. Try again or enter values manually.")
        }
        return list.map { (entry: [String: Any]) -> MealAnalysisItem in
            var item = MealAnalysisItem()
            let name = (entry["name"] as? String) ?? "Food"
            let portion = (entry["portion"] as? String) ?? ""
            item.name = portion.isEmpty ? name : "\(name) (\(portion))"
            let c = number(entry["carbs_g"])
            let f = number(entry["fat_g"])
            let p = number(entry["protein_g"])
            item.carbs = c ?? 0
            item.fat = f ?? 0
            item.protein = p ?? 0
            let complete = c != nil && f != nil && p != nil
            item.basis = complete ? basis : basis + " - missing values, check!"
            return item
        }
    }

    static func gemini(prompt: String, imageB64: String?) async throws -> [MealAnalysisItem] {
        let key = MealKeychain.get("gemini")
        guard !key.isEmpty else { throw MealError(message: "Add a Gemini key under Providers.") }
        let model = model("mealAnalysis.geminiModel", fallback: defaultGeminiModel)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw MealError(message: "Invalid Gemini model name.")
        }
        var parts: [[String: Any]] = [["text": prompt]]
        if let b64 = imageB64 {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": b64]])
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let replyParts = content["parts"] as? [[String: Any]],
              let text = replyParts.first?["text"] as? String
        else { throw MealError(message: "Gemini returned no usable text.") }
        return try parseItems(text, basis: "AI estimate (Gemini)")
    }

    static func claude(prompt: String, imageB64: String?) async throws -> [MealAnalysisItem] {
        let key = MealKeychain.get("claude")
        guard !key.isEmpty else { throw MealError(message: "Add a Claude key under Providers.") }
        let model = model("mealAnalysis.claudeModel", fallback: defaultClaudeModel)
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw MealError(message: "Invalid URL.")
        }
        var content: [[String: Any]] = []
        if let b64 = imageB64 {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]
            ])
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": content]]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first?["text"] as? String
        else { throw MealError(message: "Claude returned no usable text.") }
        return try parseItems(text, basis: "AI estimate (Claude)")
    }

    static func databaseItem(name: String, carbs: Double?, fat: Double?, protein: Double?, source: String) -> MealAnalysisItem {
        var item = MealAnalysisItem()
        item.name = name
        item.carbs = carbs ?? 0
        item.fat = fat ?? 0
        item.protein = protein ?? 0
        let complete = carbs != nil && fat != nil && protein != nil
        item.basis = complete ? "\(source), per 100 g (portion x1 = 100 g)" : "\(source) - missing values, check!"
        return item
    }

    static func usda(query: String) async throws -> [MealAnalysisItem] {
        let stored = MealKeychain.get("usda")
        let key = stored.isEmpty ? "DEMO_KEY" : stored
        guard var comps = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search") else {
            throw MealError(message: "Invalid URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "pageSize", value: "15"),
            URLQueryItem(name: "api_key", value: key)
        ]
        guard let url = comps.url else { throw MealError(message: "Invalid search text.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let json = try await send(request)
        let foods = json["foods"] as? [[String: Any]] ?? []
        return foods.compactMap { (food: [String: Any]) -> MealAnalysisItem? in
            guard let name = food["description"] as? String else { return nil }
            let nutrients = food["foodNutrients"] as? [[String: Any]] ?? []
            func value(_ id: Int) -> Double? {
                for entry in nutrients {
                    if let found = number(entry["nutrientId"]), Int(found) == id {
                        return number(entry["value"])
                    }
                }
                return nil
            }
            return databaseItem(name: name, carbs: value(1005), fat: value(1004), protein: value(1003), source: "USDA")
        }
    }

    static func offItem(_ product: [String: Any]) -> MealAnalysisItem? {
        guard let name = product["product_name"] as? String, !name.isEmpty else { return nil }
        let brand = (product["brands"] as? String) ?? ""
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        let title = brand.isEmpty ? name : "\(name) - \(brand)"
        return databaseItem(
            name: title,
            carbs: number(nutriments["carbohydrates_100g"]),
            fat: number(nutriments["fat_100g"]),
            protein: number(nutriments["proteins_100g"]),
            source: "Open Food Facts"
        )
    }

    static func openFoodFacts(query: String) async throws -> [MealAnalysisItem] {
        guard var comps = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl") else {
            throw MealError(message: "Invalid URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "15"),
            URLQueryItem(name: "fields", value: "product_name,brands,nutriments")
        ]
        guard let url = comps.url else { throw MealError(message: "Invalid search text.") }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let json = try await send(request)
        let products = json["products"] as? [[String: Any]] ?? []
        return products.compactMap { offItem($0) }
    }

    static func barcode(_ raw: String) async throws -> MealAnalysisItem {
        let digits = raw.filter { $0.isNumber }
        guard digits.count >= 6 else { throw MealError(message: "Enter a valid barcode number.") }
        let address = "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=product_name,brands,nutriments"
        guard let url = URL(string: address) else { throw MealError(message: "Invalid barcode.") }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let json = try await send(request)
        guard let product = json["product"] as? [String: Any], let item = offItem(product) else {
            throw MealError(message: "Product not found. Enter its values manually.")
        }
        return item
    }
}

// MARK: - Providers screen

struct MealProvidersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var geminiKey = ""
    @State private var claudeKey = ""
    @State private var usdaKey = ""
    @AppStorage("mealAnalysis.geminiModel") private var geminiModel = MealServices.defaultGeminiModel
    @AppStorage("mealAnalysis.claudeModel") private var claudeModel = MealServices.defaultClaudeModel

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Gemini"), footer: Text("Used for text and photo analysis.")) {
                    SecureField("API key", text: $geminiKey)
                    TextField("Model name", text: $geminiModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Claude"), footer: Text("Used for text and photo analysis.")) {
                    SecureField("API key", text: $claudeKey)
                    TextField("Model name", text: $claudeModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(
                    header: Text("USDA FoodData Central"),
                    footer: Text("Optional. Without a key, a shared demo key with low limits is used.")
                ) {
                    SecureField("API key", text: $usdaKey)
                }
                Section(
                    footer: Text(
                        "Keys are stored in this iPhone's Keychain only. Text and photos you analyze are sent to the provider you choose."
                    )
                ) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Providers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                geminiKey = MealKeychain.get("gemini")
                claudeKey = MealKeychain.get("claude")
                usdaKey = MealKeychain.get("usda")
            }
        }
    }

    private func save() {
        MealKeychain.set("gemini", value: geminiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        MealKeychain.set("claude", value: claudeKey.trimmingCharacters(in: .whitespacesAndNewlines))
        MealKeychain.set("usda", value: usdaKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Search screen

struct MealSearchView: View {
    enum Source: String, CaseIterable, Identifiable {
        case usda = "USDA"
        case off = "Open Food Facts"
        var id: String { rawValue }
    }

    let onPick: (MealAnalysisItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .usda
    @State private var query = ""
    @State private var barcodeText = ""
    @State private var results: [MealAnalysisItem] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Search foods")) {
                    Picker("Database", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("e.g. cooked white rice", text: $query)
                    Button("Search") { runSearch() }
                        .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section(header: Text("Barcode number (Open Food Facts)")) {
                    TextField("Digits under the barcode", text: $barcodeText)
                        .keyboardType(.numberPad)
                    Button("Look up barcode") { runBarcode() }
                        .disabled(busy || barcodeText.isEmpty)
                }
                if busy { Section { ProgressView() } }
                if let message { Section { Text(message).foregroundColor(.red) } }
                if !results.isEmpty {
                    Section(header: Text("Results (tap to add)")) {
                        ForEach(results) { result in
                            Button {
                                onPick(result)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).foregroundColor(.primary)
                                    Text(
                                        "C \(result.carbs, specifier: "%.1f") / F \(result.fat, specifier: "%.1f") / P \(result.protein, specifier: "%.1f") g per 100 g"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Food search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        let chosen = source
        busy = true
        message = nil
        Task {
            do {
                let found = chosen == .usda
                    ? try await MealServices.usda(query: text)
                    : try await MealServices.openFoodFacts(query: text)
                await MainActor.run {
                    results = found
                    busy = false
                    if found.isEmpty { message = "No results." }
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription
                }
            }
        }
    }

    private func runBarcode() {
        let code = barcodeText
        busy = true
        message = nil
        Task {
            do {
                let item = try await MealServices.barcode(code)
                await MainActor.run {
                    busy = false
                    onPick(item)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Camera and barcode

final class MealScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.configure()
                } else {
                    self.showMessage("Camera access was denied. Enter the barcode number instead.")
                }
            }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showMessage("No camera available. Use a physical iPhone or enter the barcode number.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showMessage("Cannot read barcodes on this device.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        guard !finished,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue
        else { return }
        finished = true
        onCode?(code)
    }
}

struct MealBarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context _: Context) -> MealScannerController {
        let controller = MealScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_: MealScannerController, context _: Context) {}
}

struct MealCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Item row

struct MealItemRow: View {
    @Binding var item: MealAnalysisItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Food name", text: $item.name)
            Text(item.basis)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                field("Carbs g", $item.carbs)
                field("Fat g", $item.fat)
                field("Protein g", $item.protein)
                field("Portion x", $item.multiplier)
            }
        }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Main screen

enum MealSheet: String, Identifiable {
    case providers
    case search
    case barcode
    case camera
    var id: String { rawValue }
}

struct MealAnalysisView: View {
    enum Provider: String, CaseIterable, Identifiable {
        case gemini = "Gemini"
        case claude = "Claude"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss

    let maxCarbs: Double
    let maxFat: Double
    let maxProtein: Double
    let onApply: (Double, Double, Double) -> Void

    @State private var items: [MealAnalysisItem] = []
    @State private var reviewed = false
    @State private var provider: Provider = .gemini
    @State private var mealText = ""
    @State private var image: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var busy = false
    @State private var message: String?
    @State private var activeSheet: MealSheet?

    private var totalCarbs: Double { items.reduce(0) { $0 + $1.scaledCarbs } }
    private var totalFat: Double { items.reduce(0) { $0 + $1.scaledFat } }
    private var totalProtein: Double { items.reduce(0) { $0 + $1.scaledProtein } }

    private var inputsValid: Bool {
        !items.isEmpty && items.allSatisfy { $0.carbs >= 0 && $0.fat >= 0 && $0.protein >= 0 && $0.multiplier > 0 }
    }

    private var withinLimits: Bool {
        totalCarbs <= maxCarbs && totalFat <= maxFat && totalProtein <= maxProtein
    }

    private var canApply: Bool { reviewed && inputsValid && withinLimits && !busy }

    var body: some View {
        NavigationView {
            Form {
                noticeSection
                aiSection
                lookupSection
                itemsSection
                totalsSection
                applySection
            }
            .navigationTitle("Analyze food")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Providers") { activeSheet = .providers }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
            }
            .onChange(of: items) { _ in reviewed = false }
            .onChange(of: photoItem) { newItem in loadPhoto(newItem) }
        }
    }

    @ViewBuilder private var noticeSection: some View {
        Section {
            Text(
                "Values are estimates. Check them against the food before applying. This screen never saves a meal or gives insulin."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var aiSection: some View {
        Section(
            header: Text("Describe or photograph the meal"),
            footer: Text("Your description and photo are sent to the selected provider.")
        ) {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("e.g. 1 cup pasta with meat sauce", text: $mealText)
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo library", systemImage: "photo")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    activeSheet = .camera
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.borderless)
            }
            if let image {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 80)
                    Spacer()
                    Button("Remove") {
                        self.image = nil
                        photoItem = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Analyze with \(provider.rawValue)") { analyze() }
                .buttonStyle(.borderless)
                .disabled(busy)
            if busy { ProgressView() }
            if let message {
                Text(message).font(.footnote).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder private var lookupSection: some View {
        Section(header: Text("Food database and barcode")) {
            Button {
                activeSheet = .search
            } label: {
                Label("Search USDA / Open Food Facts", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            Button {
                activeSheet = .barcode
            } label: {
                Label("Scan barcode", systemImage: "barcode.viewfinder")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var itemsSection: some View {
        Section(header: Text("Food items")) {
            ForEach($items) { $item in
                MealItemRow(item: $item)
            }
            .onDelete { offsets in
                items.remove(atOffsets: offsets)
            }
            Button("Add manual item") {
                items.append(MealAnalysisItem())
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var totalsSection: some View {
        Section(header: Text("Totals")) {
            Text("Carbs: \(totalCarbs, specifier: "%.1f") g")
            Text("Fat: \(totalFat, specifier: "%.1f") g")
            Text("Protein: \(totalProtein, specifier: "%.1f") g")
            if !items.isEmpty && !inputsValid {
                Text("Values must be zero or higher, and portion must be above zero.")
                    .foregroundColor(.red)
            }
            if !withinLimits {
                Text("Totals exceed your configured meal limits.").foregroundColor(.red)
            }
        }
    }

    @ViewBuilder private var applySection: some View {
        Section {
            Toggle("I reviewed these values", isOn: $reviewed)
            Button("Apply totals to the meal form") {
                onApply(totalCarbs, totalFat, totalProtein)
                dismiss()
            }
            .disabled(!canApply)
        }
    }

    @ViewBuilder private func sheetContent(_ sheet: MealSheet) -> some View {
        switch sheet {
        case .providers:
            MealProvidersView()
        case .search:
            MealSearchView { picked in items.append(picked) }
        case .barcode:
            NavigationView {
                MealBarcodeScannerView { code in
                    activeSheet = nil
                    lookupBarcode(code)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan barcode")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { activeSheet = nil }
                    }
                }
            }
        case .camera:
            MealCameraPicker { picked in image = picked }
        }
    }

    private func loadPhoto(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        Task {
            if let data = try? await newItem.loadTransferable(type: Data.self),
               let picked = UIImage(data: data)
            {
                await MainActor.run { image = picked }
            }
        }
    }

    private func lookupBarcode(_ code: String) {
        busy = true
        message = nil
        Task {
            do {
                let item = try await MealServices.barcode(code)
                await MainActor.run {
                    items.append(item)
                    busy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    busy = false
                }
            }
        }
    }

    private func analyze() {
        let text = mealText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || image != nil else {
            message = "Describe the food or add a photo first."
            return
        }
        busy = true
        message = nil
        let chosen = provider
        let picked = image
        Task {
            do {
                let b64 = picked.flatMap { MealServices.jpegBase64($0) }
                let prompt = MealServices.prompt(description: text, hasImage: b64 != nil)
                let result: [MealAnalysisItem]
                switch chosen {
                case .gemini:
                    result = try await MealServices.gemini(prompt: prompt, imageB64: b64)
                case .claude:
                    result = try await MealServices.claude(prompt: prompt, imageB64: b64)
                }
                await MainActor.run {
                    items.removeAll { $0.basis.hasPrefix("AI") }
                    items.append(contentsOf: result)
                    busy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    busy = false
                }
            }
        }
    }
}

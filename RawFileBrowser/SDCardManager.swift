import Foundation; import UIKit; import Combine
struct RAWFile: Identifiable {
    let id = UUID(); let url: URL
    var name: String { url.lastPathComponent }
    var size: Int64 { (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize.map(Int64.init) ?? 0) ?? 0 }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount:size, countStyle:.file) }
    var modificationDate: Date? { try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate }
    var fileExtension: String { url.pathExtension.uppercased() }
    var focusStatus: FocusStatus = .unanalyzed; var focusScore: Double = 0
    var focusRegion: FocusResult.AnalysisRegion = .fullImage; var blurType: BlurType = .unknown
    var subjectSizeConfidence: Double = 0; var detectedAnimalLabel: String? = nil
    var analysisRect: CGRect? = nil; var detectionConfidence: Float? = nil
    var xmpWritten: Bool = false; var isRejected: Bool { focusStatus.isRejected }
}
extension RAWFile: Hashable, Equatable {
    static func ==(lhs:RAWFile,rhs:RAWFile)->Bool{lhs.id==rhs.id}
    func hash(into hasher:inout Hasher){hasher.combine(id)}
}
private let rawExtensions:Set<String>=["raw","arw","cr2","cr3","nef","nrw","orf","rw2","pef","raf","srw","dng","3fr","fff","iiq","rwl","mrw","x3f","erf","kdc","dcr","mef","mos","ptx"]
@MainActor final class SDCardManager: ObservableObject {
    @Published var rawFiles:[RAWFile]=[]; @Published var isSDCardMounted=false
    @Published var isLoading=false; @Published var isAnalyzing=false
    @Published var analysisProgress:Double=0; @Published var errorMessage:String?
    private var activeDirectoryURL:URL?{didSet{oldValue?.stopAccessingSecurityScopedResource()}}
    deinit{activeDirectoryURL?.stopAccessingSecurityScopedResource()}
    func refresh(){guard !isSDCardMounted else{return};isLoading=true;errorMessage=nil;Task{let f=scanForRAWFiles();rawFiles=f;if !f.isEmpty{isSDCardMounted=true};isLoading=false}}
    func forceRefresh(){activeDirectoryURL=nil;isSDCardMounted=false;rawFiles=[];isLoading=true;errorMessage=nil;Task{let f=scanForRAWFiles();rawFiles=f;isSDCardMounted = !f.isEmpty||detectExternalVolumes();isLoading=false}}
    func loadFilesFromDirectory(_ url:URL){activeDirectoryURL=url;isLoading=true;errorMessage=nil;let found=collectRAWFiles(in:url);isSDCardMounted=true;rawFiles=found.sorted{$0.name<$1.name};isLoading=false;if found.isEmpty{errorMessage="No RAW files found."}}
    func analyzeAllFocus() async {
        guard !rawFiles.isEmpty else{return};isAnalyzing=true;analysisProgress=0;let total=rawFiles.count
        for batchStart in stride(from:0,to:total,by:4){let batchEnd=min(batchStart+4,total)
            await withTaskGroup(of:(Int,FocusResult).self){group in
                for i in batchStart..<batchEnd{let url=rawFiles[i].url;group.addTask{(i,await FocusAnalyzer.analyze(url:url))}}
                for await(i,r)in group{rawFiles[i].focusStatus=r.status;rawFiles[i].focusScore=r.score;rawFiles[i].focusRegion=r.analysisRegion;rawFiles[i].blurType=r.blurType;rawFiles[i].subjectSizeConfidence=r.subjectSizeConfidence;rawFiles[i].detectedAnimalLabel=r.detectedAnimalLabel;rawFiles[i].analysisRect=r.analysisRect;rawFiles[i].detectionConfidence=r.detectionConfidence}
            };analysisProgress=Double(batchEnd)/Double(total)}
        isAnalyzing=false
    }
    func analyzeFocus(for file:RAWFile) async {
        guard let idx=rawFiles.firstIndex(where:{$0.id==file.id}) else{return}
        let r=await FocusAnalyzer.analyze(url:file.url)
        rawFiles[idx].focusStatus=r.status;rawFiles[idx].focusScore=r.score;rawFiles[idx].focusRegion=r.analysisRegion;rawFiles[idx].blurType=r.blurType;rawFiles[idx].subjectSizeConfidence=r.subjectSizeConfidence;rawFiles[idx].detectedAnimalLabel=r.detectedAnimalLabel;rawFiles[idx].analysisRect=r.analysisRect;rawFiles[idx].detectionConfidence=r.detectionConfidence
    }
    var rejectedCount:Int{rawFiles.filter(\.isRejected).count}
    func markXMPWritten(for file:RAWFile){guard let idx=rawFiles.firstIndex(where:{$0.id==file.id})else{return};rawFiles[idx].xmpWritten=true}
    func writeXMP(for file:RAWFile){guard let idx=rawFiles.firstIndex(where:{$0.id==file.id})else{return};do{try XMPSidecarWriter.write(for:file);rawFiles[idx].xmpWritten=true}catch{errorMessage=error.localizedDescription}}
    func writeXMPBatch()->String{let e=rawFiles.filter{$0.detectedAnimalLabel != nil};let r=XMPSidecarWriter.writeBatch(for:e);for i in rawFiles.indices where rawFiles[i].detectedAnimalLabel != nil{rawFiles[i].xmpWritten=XMPSidecarWriter.sidecarExists(for:rawFiles[i])};var s="\(r.written) XMP file(s) written";if r.skipped>0{s+=", \(r.skipped) skipped"};if !r.errors.isEmpty{s+=", \(r.errors.count) error(s)"};return s}
    private func collectRAWFiles(in d:URL)->[RAWFile]{guard let e=FileManager.default.enumerator(at:d,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey],options:[.skipsHiddenFiles])else{return[]};return e.compactMap{$0 as? URL}.filter{rawExtensions.contains($0.pathExtension.lowercased())}.map{RAWFile(url:$0)}}
    private func scanForRAWFiles()->[RAWFile]{var r:[RAWFile]=[];if let v=try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:"/Volumes"),includingPropertiesForKeys:nil,options:.skipsHiddenFiles){for vol in v{r+=collectRAWFiles(in:vol)}};if let d=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.deletingLastPathComponent().appendingPathComponent("Media/DCIM"){r+=collectRAWFiles(in:d)};return r}
    private func detectExternalVolumes()->Bool{(try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:"/Volumes"),includingPropertiesForKeys:nil,options:.skipsHiddenFiles))?.isEmpty==false}
}

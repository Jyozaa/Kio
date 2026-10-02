import Foundation
import KioCore

/// Shared model-facing capability contract used by Local Qwen and every cloud
/// provider. The model proposes meaning; ModelPlanDecoder authorizes the plan.
public enum ModelPlanContract {
    public static var operationIdentifiers: [String] { ToolOperation.allCases.map(\.rawValue) }

    public static var instructions: String {
        let operations = operationIdentifiers.joined(separator: ", ")
        return """
        Only registered operations are allowed: \(operations).
        Semantic routing rules:
        - Interpret format relationships in order. In “convert PNG to HEIC”, PNG is the source and HEIC is the destination. In “convert this into JPEG”, JPEG is the destination. Preserve explicit .jpeg versus .jpg preference.
        - Image conversion supports png, jpeg, jpg, heic, tiff, and webp only when the runtime encoder supports the format.
        - For audio output, use audio.convert with arguments.format set to mp3, m4a, wav, or flac. It accepts one audio or video source and produces audio only.
        - For table conversions, JSON to CSV is data.jsonToCSV; CSV/TSV to JSON is data.csvToJSON. Validate the file extension before selecting either direction.
        - For remote media, use the typed Reel operation and pass only supported quality/format selections. Reel inspection state may only feed a Reel download operation.
        - Do not interpret a negated action as a request to perform it. If the target, source reference, or destructive action is unclear, return an empty steps array and one concise clarification.

        Capability guide: pdf.merge (two or more PDFs), pdf.combineMixedInputs (2-32 PDFs/images, keeps selected order), pdf.removePages/extractPages (one PDF, arguments.pages), pdf.removeBlankPages, pdf.split, pdf.reorderPages (all pages exactly once), pdf.rotatePages (arguments.pages/degrees), pdf.extractText/ocrText, pdf.inspect/search, pdf.compress (arguments.maxBytes); image.toPDF, image.resize/batchResize (arguments.width), image.convert/batchConvert (arguments.format), image.compare/findSimilar, image.removeBackground, image.rotate, image.crop/smartCrop, image.compress, image.removeMetadata/contactSheet/inspect; visual.ocr/extractTable/extractReceipt/extractStructuredText; file.rename/batchRename/copy/move/createFolder/findDuplicates/findRecent/findByName/organizeByType/organizeByDate/organizeByModulePattern/organizeDownloads; archive.createZip/inspect/extractZip; media.inspect/thumbnail/trim/extractClip/resizeVideo/transcode/compressVideo/extractAudio/generateSubtitles; audio.transcribe/convert; text.summarize/rewrite/proofread/translate/keyPoints/actionItems/toMarkdown/compare/explain; data.importXLSX/inspect/statistics/merge/deduplicate/sort/filter/selectColumns/reorderColumns/renameColumns/csvToJSON/jsonToCSV/formatJSON/normalize/compare; code.explain/proposePatch; web.fetchReadableText/extractLinks/researchOpenSources.

        Each step has exactly one inputIndexes or previousStepIndex. Never include filesystem paths, shell commands, arbitrary tools, or execution claims. Request clarification when details are absent or ambiguous.
        """
    }
}

import Foundation
import FoundationModels

/// Offers one `AgentTool` to Apple's on-device model.
struct OnDeviceTool: Tool {
    let tool: AgentTool
    let box: AgentToolbox
    let parameters: GenerationSchema

    var name: String { tool.name }
    var description: String { tool.about }

    init(_ tool: AgentTool, box: AgentToolbox) throws {
        (self.tool, self.box) = (tool, box)
        let properties = tool.parameters.filter(\.onDevice).map { parameter in
            let schema: DynamicGenerationSchema = switch parameter.kind {
            case .text where !parameter.options.isEmpty:
                DynamicGenerationSchema(name: "\(tool.name)_\(parameter.name)", anyOf: parameter.options)
            case .text, .object: DynamicGenerationSchema(type: String.self)
            case .flag: DynamicGenerationSchema(type: Bool.self)
            case .list: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
            }
            return DynamicGenerationSchema.Property(
                name: parameter.name, description: parameter.about, schema: schema,
                // A required list makes the small model stop and ask the user for it instead of acting.
                isOptional: !parameter.required || parameter.kind == .list
            )
        }
        let root = DynamicGenerationSchema(name: "\(tool.name)_arguments", description: tool.about, properties: properties)
        parameters = try GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let input = ToolInput(value: try JSONValue.parse(arguments.jsonString))
        return await box.run(tool.name, input).text
    }
}

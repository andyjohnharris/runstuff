import SwiftUI

enum RunStuffStyle {
  static let canvas = Color(red: 0.082, green: 0.090, blue: 0.106)
  static let surface = Color(red: 0.122, green: 0.133, blue: 0.157)
  static let raised = Color(red: 0.145, green: 0.161, blue: 0.188)
  static let border = Color(red: 0.200, green: 0.216, blue: 0.247)
  static let text = Color(red: 0.941, green: 0.949, blue: 0.969)
  static let secondary = Color(red: 0.635, green: 0.671, blue: 0.729)
  static let mint = Color(red: 0.157, green: 0.808, blue: 0.616)
  static let coral = Color(red: 1, green: 0.427, blue: 0.447)
  static let blue = Color(red: 0.365, green: 0.647, blue: 1)
  static let title = Font.system(size: 22, weight: .semibold)
  static let heading = Font.system(size: 15, weight: .semibold)
  static let body = Font.system(size: 13)
  static let caption = Font.system(size: 11, weight: .medium)
  static let code = Font.system(size: 12, design: .monospaced)
  static let radius: CGFloat = 14
  static let inset: CGFloat = 16
  static let panelWidth: CGFloat = 420
  static let panelHeight: CGFloat = 620
  static let feedback = Animation.easeOut(duration: 0.12)
  static let transition = Animation.easeInOut(duration: 0.20)
}

struct StuffCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RunStuffStyle.surface, in: RoundedRectangle(cornerRadius: RunStuffStyle.radius))
      .overlay(RoundedRectangle(cornerRadius: RunStuffStyle.radius).stroke(RunStuffStyle.border))
  }
}

struct StuffButtonStyle: ButtonStyle {
  var tint: Color = RunStuffStyle.secondary
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .padding(.horizontal, 12)
      .frame(minHeight: 32)
      .foregroundStyle(tint)
      .background(
        tint.opacity(configuration.isPressed ? 0.24 : 0.10), in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.18)))
      .opacity(isEnabled ? 1 : 0.4)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : RunStuffStyle.feedback, value: configuration.isPressed)
  }
}

struct RunningCountLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.icon.font(.system(size: 10)).foregroundStyle(RunStuffStyle.mint)
      configuration.title
    }
  }
}

struct StuffActionLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 8) {
      configuration.icon.font(.system(size: 18))
      configuration.title.font(RunStuffStyle.caption)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }
}

extension View {
  func stuffTheme() -> some View {
    self
      .font(RunStuffStyle.body)
      .foregroundStyle(RunStuffStyle.text)
      .tint(RunStuffStyle.mint)
      .background(RunStuffStyle.canvas)
      .preferredColorScheme(.dark)
  }
}

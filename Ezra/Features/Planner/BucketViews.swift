import SwiftUI

struct BucketBadge: View {
    let bucket: Bucket
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: bucket.symbol)
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(bucket.tint, in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// Three chips for choosing a bucket.
struct BucketChips: View {
    @Binding var selection: Bucket

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips(showsTitles: true)
            chips(showsTitles: false)
        }
        .foregroundStyle(Brand.Palette.ink)
    }

    private func chips(showsTitles: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Bucket.allCases) { bucket in
                Button {
                    withAnimation(.snappy(duration: 0.15)) { selection = bucket }
                } label: {
                    HStack(spacing: 5) {
                        BucketBadge(bucket: bucket, size: 16)
                        if showsTitles { Text(bucket.title).font(Brand.Fonts.label).fixedSize() }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(selection == bucket ? bucket.tint.opacity(0.16) : .clear, in: .rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selection == bucket ? bucket.tint : Brand.Palette.hairline, lineWidth: 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.hand)
                .accessibilityLabel(bucket.title)
                .accessibilityAddTraits(selection == bucket ? .isSelected : [])
            }
        }
    }
}

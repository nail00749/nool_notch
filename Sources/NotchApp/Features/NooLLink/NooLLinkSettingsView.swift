import AppKit
import SwiftUI

struct NooLLinkSettingsView: View {
    @ObservedObject var service: NooLLinkService
    @ObservedObject private var airDrop = NooLAirDropCoordinator.shared

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Подключение", icon: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Включить NooL Link", isOn: Binding(
                        get: { service.isEnabled },
                        set: { service.setEnabled($0) }
                    ))

                    Label(service.connectionState, systemImage: service.pairedDeviceName == nil ? "wifi.slash" : "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)

                    if let device = service.pairedDeviceName {
                        HStack {
                            Text("Связанное устройство")
                                .foregroundStyle(NotchPalette.secondary)
                            Spacer()
                            Text(device).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        Button("Отвязать устройство", role: .destructive) {
                            service.unpair()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("Создайте код приглашения и введите его в приложении NooL Link на Windows. Оба компьютера должны быть в одной локальной сети.")
                            .font(.system(size: 11))
                            .foregroundStyle(NotchPalette.secondary)

                        Button {
                            service.createInvitation()
                        } label: {
                            Label("Создать код приглашения", systemImage: "qrcode")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.isEnabled)

                        if let invitation = service.invitation {
                            HStack(spacing: 8) {
                                Text(invitation)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer(minLength: 4)
                                Button {
                                    let item = NSPasteboardItem()
                                    item.setString(invitation, forType: .string)
                                    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([item])
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .help("Скопировать код")
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            Text("Код действует ограниченное время. Передайте его только своему компьютеру.")
                                .font(.system(size: 10))
                                .foregroundStyle(NotchPalette.secondary)
                        }
                    }
                }
            }

            SettingsCard(title: "Синхронизация", icon: "doc.on.clipboard") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Синхронизировать текст и изображения", isOn: $service.clipboardSyncEnabled)
                    Toggle("Передавать файлы", isOn: $service.fileTransferEnabled)
                    Toggle("Показывать Windows в AirDrop", isOn: $airDrop.isEnabled)
                        .disabled(!service.fileTransferEnabled)
                    Text(airDrop.status)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.secondary)
                    if let transfer = service.fileTransferState {
                        Text(transfer)
                            .font(.system(size: 11))
                            .foregroundStyle(NotchPalette.secondary)
                    }
                    Text("Передача доступна только связанному компьютеру в локальной сети. Можно отправить до 64 обычных файлов общим размером до 32 МиБ; папки не поддерживаются. История буфера Launcher настраивается отдельно.")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.secondary)
                }
                .disabled(!service.isEnabled || service.pairedDeviceName == nil)
            }

            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.signalAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(NotchPalette.text)
    }
}

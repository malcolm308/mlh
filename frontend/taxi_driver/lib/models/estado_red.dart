/// Estado de conectividad que se pinta en el widget flotante del chofer.
enum EstadoRed {
  /// Sin interfaz de red o el backend no responde: no llegarán ofertas.
  sinSenal,

  /// Hay red, pero la conexión es lenta o ha fallado una vez: puede tardar.
  debil,

  /// Red sana. El widget de red se oculta por completo.
  buena,
}

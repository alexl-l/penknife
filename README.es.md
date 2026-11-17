<div align="center">

<img src="docs/screenshots/icon.png" width="128" alt="Icono de Penknife">

# Penknife

**Silencia la reunión en la que estás, encuentra lo que copiaste, marca cualquier captura.**<br>
Una app diminuta de la barra de menús para tu Mac. Gratis y de código abierto.

<a href="https://github.com/alexl-l/penknife/releases/latest"><img src="https://img.shields.io/badge/Descargar_para_macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Descargar para macOS"></a>

<img src="https://img.shields.io/badge/macOS-26%2B-555?style=flat-square" alt="macOS 26+">
<img src="https://img.shields.io/github/v/release/alexl-l/penknife?style=flat-square&label=versi%C3%B3n" alt="Última versión">
<img src="https://img.shields.io/badge/licencia-MIT-555?style=flat-square" alt="Licencia MIT">

[English](README.md) · **Español**

</div>

## Qué incluye

Cada parte es un módulo. Desactiva lo que no necesites y no gastará CPU ni memoria. Funciona en cualquier Mac; no necesitas Touch Bar.

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/screenshots/menu.png" alt="Menú de la barra de menús">
<h3>Silenciar el micrófono en reuniones</h3>
Un atajo silencia la reunión en la que estás: Teams, Google Meet, Zoom, Slack Huddles o Webex. Solo cuentan las apps con una llamada en curso, y cada una usa su propio atajo, que puedes editar en Ajustes. Sin llamada, silencia el micrófono del Mac. El icono y el punto de estado muestran siempre el estado real.
</td>
<td width="50%" valign="top">
<img src="docs/screenshots/clipboard.png" alt="Historial del portapapeles">
<h3>Historial del portapapeles</h3>
Busca, fija lo que más usas y pega con ⌘1–⌘9. Nunca guarda contraseñas ni otros elementos ocultos.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/screenshots/screenshot-editor.jpg" alt="Editor de capturas">
<h3>Capturas de pantalla</h3>
Selecciona una zona o una ventana, márcala con flechas, texto, resaltador, formas, lápiz y desenfoque, y copia o guarda. No se sube nada a internet.
</td>
<td width="50%" valign="top">
<img src="docs/screenshots/settings-music.png" alt="Ajustes de música">
<h3>Música</h3>
Reproduce, pausa y salta canciones en el reproductor que elijas. Los clics de los auriculares van a ese reproductor, y Apple Music ya no se abre solo.
</td>
</tr>
</table>

### Y en la barra de menús
Mover el ratón para mantener el Mac despierto y tu estado activo, bloquear la pantalla y un test de velocidad que muestra bajada, subida y latencia en kbps, Mbps o Gbps. Cada opción tiene su propio atajo y unos puntos de estado muestran lo que está activado. Los avisos son discretos, y tú eliges cuáles aparecen y cuánto duran.

### Ajustes
Una sola ventana al estilo de Ajustes del Sistema: activa o desactiva cada módulo y dale su propio atajo.

<img src="docs/screenshots/settings.png" alt="Ajustes de Penknife">

### ¿Tienes Touch Bar?
Penknife añade la suya: brillo, luz del teclado, volumen, música, tiempo, temperatura de la CPU, batería, test de velocidad y hora, a un toque. Los iconos siguen el estado actual y tú eliges qué botones aparecen y en qué orden.

<img src="docs/screenshots/touchbar-rainbow.png" alt="Touch Bar de Penknife en modo arcoíris">

<img src="docs/screenshots/touchbar.png" alt="Touch Bar de Penknife">

Un extra: mantén pulsado el botón de mover el ratón 3 segundos y corta fruta en la Touch Bar.

<img src="docs/screenshots/touchbar-game.png" alt="Juego de cortar fruta en la Touch Bar">

## Instalación

¿Prefieres Homebrew? Ejecuta `brew trust alexl-l/tap && brew install --cask alexl-l/tap/penknife`. Si no:

1. [Descarga la última versión](https://github.com/alexl-l/penknife/releases/latest), descomprímela y mueve `Penknife.app` a `/Aplicaciones`.
2. Ábrela. Penknife no está notarizada (no hay cuenta de pago de Apple Developer), así que macOS la bloquea la primera vez: ve a **Ajustes del Sistema → Privacidad y seguridad** y pulsa **Abrir igualmente**.
3. Listo. Penknife busca actualizaciones una vez al día y pregunta antes de instalarlas (menú → **Buscar actualizaciones…**).

<details>
<summary><b>Requisitos</b></summary>

- macOS 26 o posterior, en cualquier Mac.
- La sección Touch Bar es opcional y necesita un MacBook Pro con Touch Bar.

</details>

<details>
<summary><b>Permisos</b></summary>

Penknife pide solo lo que necesitan los módulos que actives:

- **Accesibilidad**: atajos que actúan sobre otras apps, teclas multimedia, mover el ratón y leer el botón de silencio de la reunión para que la llamada y el Mac coincidan.
- **Automatización (Apple Events)**: para controlar Spotify y Apple Music.
- **Ubicación** (opcional): el tiempo local.
- **Grabación de pantalla**: capturas de pantalla.

</details>

<details>
<summary><b>En Chrome, la reunión y el micrófono del Mac no coinciden</b></summary>

Al pulsar el atajo, Penknife lee el botón de silencio de la reunión para que la llamada y el micrófono del Mac queden igual. Chrome solo muestra ese botón a otras apps si su accesibilidad está activa, y se puede bloquear:

1. Abre `chrome://accessibility` (`opera://accessibility`, `edge://accessibility` o `brave://accessibility` en esos navegadores).
2. Comprueba que **Suppress automatic accessibility enablement from platform API consumers** está desmarcada. Deja también desmarcada **Lock the current accessibility mode**.
3. **Native accessibility API support** y **Web accessibility** deben estar activas (se activan solas cuando nada las bloquea). Las demás casillas no hacen falta.

Safari no necesita nada. Si no se puede leer el botón, Penknife envía igualmente el atajo de la reunión.

</details>

<details>
<summary><b>Privacidad</b></summary>

Penknife no tiene cuenta, ni analíticas, ni rastreo.

- **El tiempo** envía a [Open-Meteo](https://open-meteo.com/) solo coordenadas redondeadas a unos 11 km. Open-Meteo ve tu dirección IP.
- **El test de velocidad** usa la herramienta `networkQuality` de macOS, que contacta con servidores de prueba de Apple.
- **El historial del portapapeles** y **las capturas** se quedan en tu Mac.

</details>

<details>
<summary><b>APIs privadas</b></summary>

Penknife no es una app de la App Store. Usa algunos frameworks privados de macOS, por ejemplo para mostrar su propia Touch Bar y ajustar el brillo de la pantalla y del teclado. Una actualización de macOS puede romper un módulo. Si pasa, ese módulo deja de funcionar y el resto de la app sigue.

</details>

<details>
<summary><b>Compilar desde el código</b></summary>

1. Crea un certificado de firma de código llamado `Penknife Local Signing` en tu llavero de inicio de sesión (Acceso a Llaveros → Asistente de certificados → Crear un certificado, tipo *Firma de código*). Una firma estable conserva los permisos de privacidad entre compilaciones.
2. Ejecuta `scripts/install.sh`. Compila una versión Release, la firma y la instala en `/Aplicaciones`.

</details>

Consulta [CHANGELOG.md](CHANGELOG.md) para ver los cambios de cada versión.

## Licencia

[MIT](LICENSE). Avisos de terceros: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

Penknife no está afiliada ni respaldada por Apple ni Spotify. Los nombres se usan solo para describir la compatibilidad.

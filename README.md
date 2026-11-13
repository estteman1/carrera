# Carrera de Observación — Hacienda Fontanar

Aplicación web móvil para la carrera del cumpleaños de Sandra Díaz: dashboard público en vivo, mapa por estaciones, sorteo con dados, Mamá Comodín, panel de administración, imágenes para WhatsApp y modo manual sin conexión.

## Arquitectura

| Capa | Tecnología | Por qué |
|---|---|---|
| Frontend | React 19 + TypeScript (estricto) + Vite + Tailwind | SPA estática: se publica en Vercel/Netlify sin servidor propio |
| Motor de reglas | `src/engine/` (TypeScript puro, 17 pruebas) | Una sola fuente de verdad para puntos, tiempos, permisos y clasificación |
| Datos | Log inmutable de acciones (event sourcing) | Auditoría completa, anulaciones trazables, deduplicación al reconectar |
| Backend | Supabase (PostgreSQL + Realtime) | `supabase/schema.sql`: RLS, escritura solo por RPC con PIN, hora del servidor |
| Mapa | Leaflet + OpenStreetMap | Estaciones ubicadas por el admin; equipos en su última estación confirmada (no GPS) |
| Imágenes | Canvas nativo | PNG vertical (WhatsApp) y horizontal (TV), sin datos privados |

Sin variables de Supabase la app funciona en **Modo manual** (datos en el dispositivo, sincroniza pestañas del mismo navegador).

## Correr localmente

```bash
npm install
npm run dev        # http://localhost:5173
npx vitest run     # pruebas del motor
```

PIN provisionales en modo manual: Admin `1234`, Juez `2222`, Mamá Comodín `3333`. Códigos de equipo: `AZUL1`, `ROJO2`, `VERDE3`, `AMARILLO4`. **Cámbialos en Administración → Accesos.**

## Publicar con tiempo real (≈15 min)

1. **Supabase** (plan gratuito): crea un proyecto en supabase.com.
2. SQL Editor → pega todo `supabase/schema.sql` → *Run*.
3. En el mismo editor, ejecuta (con tus PIN definitivos, mínimo 4 caracteres):
   ```sql
   select race_bootstrap('fontanar', 'PIN-ADMIN', 'PIN-JUEZ', 'PIN-MAMA');
   ```
4. Project Settings → API: copia **Project URL** y **anon public key**.
5. **Vercel**: importa este proyecto (desde GitHub o `npx vercel`), framework *Vite*, y agrega variables:
   ```
   VITE_SUPABASE_URL=https://xxxx.supabase.co
   VITE_SUPABASE_ANON_KEY=eyJ...
   VITE_EVENT_ID=fontanar
   ```
6. Deploy. Entra con el PIN de admin → Accesos: define códigos de equipo y teléfono de Mamá Comodín.

La anon key es pública por diseño: el público solo puede leer; toda escritura pasa por `race_submit_action`, que verifica el PIN (bcrypt) y el rol.

## Día del evento

1. **Antes**: Datos → Reiniciar (borra la demo). Configurar → nombres de equipos y pruebas. Mapa → ubica salida, 4 estaciones, meta y zonas restringidas.
2. **Sorteo**: Más → Sorteo de dados. Registra lo que salió en los dados físicos (o usa el dado virtual). Los empates relanzan solos.
3. **Salidas**: Administración → Carrera → “¡Dar salida ahora!” en cada turno. La hora real queda registrada; cada equipo cronometra desde su salida.
4. **Pruebas**: el capitán avisa llegada y pide validación desde *Mi equipo* (QR). El organizador aprueba ✓ o rechaza ✗. La prueba 3 la aprueba Mamá Comodín (PIN propio) o el admin registra su decisión “por llamada”.
5. **Pistas**: el equipo pide la pista; solo descuenta cuando Mamá Comodín confirma “Pista entregada”.
6. **Errores**: Historial → Anular (con motivo). Nada se borra.
7. **Final**: “Finalizar carrera y declarar ganador” → Resultados → imagen para WhatsApp.

## Si se cae internet

- El indicador superior cambia a **Sin conexión** y muestra la hora de los últimos datos.
- Puedes seguir registrando: quedan en cola con la hora corregida y se envían al volver la señal. El servidor ignora duplicados.
- Comparte la clasificación como **imagen** (Compartir → Vertical) en el grupo de WhatsApp.
- Sin Supabase disponible en absoluto: usa un solo celular del organizador en modo manual y comparte imágenes.

## Estado

- ✅ Implementado y probado: motor de reglas, dados con desempate, relojes individuales, permisos por rol, Mamá Comodín, pistas, anulaciones, pausas, clasificación en carrera y final, demo guiada, modo manual, imágenes PNG, QR, WhatsApp, mapa editable.
- ✅ SQL probado en PostgreSQL 16: permisos, deduplicación, secretos, vista de equipo.
- ⏳ Por verificar en el proyecto Supabase real: suscripción Realtime entre dos celulares.
- ⏳ Pendiente: GPS opcional (Modalidad B), plano de Fontanar como capa (requiere autorización de uso).

# Pes Costa Rica · cómo publicarla

La página es un sitio estático (sin instalar nada) conectado a Supabase.

| Archivo | Para qué sirve |
|---|---|
| `index.html` | La página completa |
| `config.js` | Aquí se pegan la Project URL y la llave anon/publishable de Supabase |
| `logo.webp` | Escudo de la comunidad |
| `vendor/xlsx.full.min.js` | Lector de Excel para importar y exportar |
| `supabase/instalar.sql` | Crea la base de datos (se pega una vez en Supabase) |
| `vercel.json` | Ajustes de publicación en Vercel |

## 1. Base de datos (Supabase)
1. Supabase → tu proyecto → **SQL Editor** → **New query**.
2. Copia **todo** el contenido de `supabase/instalar.sql`, pégalo y pulsa **Run**.
3. Debe salir "Success". Se puede volver a ejecutar sin perder datos.

## 2. Conectar la página
1. Supabase → **Project Settings** → **API Keys** (o **Data API**): copia la **Project URL** y la llave **anon / publishable**.
2. En GitHub abre `config.js` → lápiz ✏️ → pega los dos datos entre las comillas → **Commit changes**.
3. Nunca uses la llave **service_role** ni la **secret**.

## 3. Publicar (Vercel)
1. Vercel → **Add New… → Project** → importa `pes-costa-rica`.
2. Framework Preset: **Other**. No cambies nada más → **Deploy**.
3. Cada cambio que hagas en GitHub se publica solo en 1 minuto.

## 4. Primeros pasos
1. Entra a la página y pulsa **Unirme** con el ID **Lgsoto92** (administrador principal).
2. Luis Marin se inscribe con **LMarin** (administrador).
3. Háganlo antes de compartir el enlace: esos dos ID ya tienen permisos reservados.
4. En **Admin → Importar Excel** pueden cargar el historial.

## Seguridad
- Las contraseñas se guardan cifradas (bcrypt).
- Cada cambio a un partido o torneo guarda la versión anterior (tabla `item_versions`).
- Los miembros solo pueden reportar sus propios resultados (quedan pendientes), cambiar su foto, país y contraseña, e inscribirse a torneos.
- Nadie, salvo Lgsoto92, puede quitarle permisos o cambiarle la contraseña al administrador principal.

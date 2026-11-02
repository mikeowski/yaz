import Foundation

/// High-frequency Spanish words: the term-repair veto for Spanish.
///
/// With no list, 5 of 30 everyday Spanish sentences changed: "curso" and
/// "carrera" became Cursor, "doctor" Docker, "vamos al" Vercel. With it, none
/// of the 30 and none of 20 held out change.
enum SpanishLexicon {

    static let protectedWordThreshold: Double = 0.90

    static func isCommon(_ word: String) -> Bool {
        let folded = word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(CharacterSet(charactersIn: "¿¡")))
        guard !folded.isEmpty else { return false }
        if common.contains(folded) { return true }
        for suffix in ["s", "es"] where folded.count > suffix.count + 2 {
            if folded.hasSuffix(suffix), common.contains(String(folded.dropLast(suffix.count))) { return true }
        }
        return false
    }

    private static let common: Set<String> = [
        "a", "abandonar", "abandoné", "abierta", "abierto", "abuela", "abuelo", "abuelos", "además",
        "adiós", "aeropuerto", "agua", "ahora", "ahí", "al", "alegramos", "alegrar", "algo", "alguien",
        "allí", "alquiler", "alto", "amiga", "amigo", "amigos", "anoche", "antes", "apretados", "aprobar",
        "aprobó", "apuntar", "apunté", "aquel", "aquella", "aquí", "arroz", "así", "aunque", "autobús",
        "avión", "ayer", "azúcar", "añadir", "añadí", "año", "años", "aún", "bajo", "balcón", "banco",
        "barato", "batería", "baño", "bici", "bien", "buena", "bueno", "buscar", "cada", "café", "calle",
        "cama", "camisa", "cancelamos", "cancelar", "cansado", "cara", "cargador", "carne", "caro",
        "carrera", "carta", "casa", "casas", "casi", "cena", "cerrada", "cerrado", "cine", "ciudad",
        "claro", "clase", "coche", "coches", "cocina", "cocinar", "cocino", "colegio", "come", "comer",
        "comida", "como", "compra", "comprar", "comí", "con", "conocer", "contra", "corre", "correo",
        "correos", "correr", "corta", "cortar", "cortinas", "corto", "corté", "cosa", "cosas", "cree",
        "creer", "creo", "cual", "cuando", "curso", "cuál", "cuándo", "cómo", "da", "dar", "de", "debe",
        "deber", "debería", "decir", "deja", "dejar", "dejo", "dejé", "dejó", "del", "demasiado",
        "desayuno", "desde", "después", "dice", "dicho", "difícil", "digo", "dijo", "dinero", "dio",
        "discutimos", "discutir", "doctor", "donde", "doy", "dura", "durante", "duro", "día", "días",
        "dónde", "e", "el", "ella", "ellas", "ellos", "empezar", "empieza", "en", "encontrar", "enfermo",
        "entonces", "entre", "era", "eran", "eres", "es", "esa", "esas", "escribir", "escribió", "escuela",
        "ese", "eso", "esos", "esperando", "esperar", "espero", "esta", "estaba", "estación", "estado",
        "estamos", "estar", "estas", "este", "esto", "estos", "estoy", "estuve", "está", "están", "estás",
        "examen", "factura", "familia", "farmacia", "favor", "feliz", "fin", "flor", "flores", "fruta",
        "fue", "fueron", "fui", "fácil", "gato", "gracias", "grande", "ha", "haber", "habla", "hablar",
        "habló", "había", "hace", "hacemos", "hacen", "hacer", "hacia", "hago", "han", "has", "hasta",
        "hay", "he", "hecho", "hemos", "hermana", "hermano", "hicimos", "hija", "hijo", "hijos", "hizo",
        "hola", "hombre", "hora", "horas", "hotel", "hoy", "hubo", "huevo", "iba", "idea", "ido",
        "impresora", "ir", "jardín", "jefe", "joven", "jugando", "jugar", "la", "largo", "las", "lavar",
        "lavé", "le", "leche", "lenta", "lento", "les", "levantar", "levanté", "libre", "libro", "libros",
        "lista", "listo", "llamar", "llamó", "llaves", "llega", "llegar", "llego", "llegué", "llegó",
        "lleno", "lleva", "llevar", "llevo", "llevé", "lluvia", "lo", "los", "luego", "luz", "madre", "mal",
        "mala", "malo", "mandar", "mañana", "me", "mejor", "menos", "mensaje", "mercado", "mes", "mesa",
        "meses", "mi", "mientras", "minuto", "minutos", "mis", "misma", "mismo", "mitad", "mover", "movió",
        "mucha", "muchas", "mucho", "muchos", "mujer", "muy", "más", "médico", "nada", "nadie", "necesita",
        "necesitar", "ni", "niña", "niño", "niños", "no", "noche", "nos", "nosotros", "nuestra", "nuestro",
        "nueva", "nuevo", "nuevos", "nunca", "o", "obra", "ocupado", "oficina", "olvidar", "olvides",
        "olvidé", "ordenador", "os", "otra", "otras", "otro", "otros", "paces", "padre", "padres", "pagar",
        "pagué", "pan", "pantalla", "papel", "para", "paraguas", "parece", "parecer", "parte", "partido",
        "pasa", "pasar", "pasta", "pastillas", "pasó", "patio", "país", "pedir", "pedí", "pelo", "pensar",
        "peor", "pequeña", "pequeño", "perdón", "pero", "perro", "pescado", "pienso", "planchar",
        "plancharlas", "planta", "plantas", "poca", "pocas", "poco", "pocos", "podar", "podemos", "poder",
        "podía", "pone", "poner", "pongo", "por", "porque", "portátil", "precio", "preciosa", "pregunta",
        "preparar", "preparé", "prestar", "presto", "primera", "primero", "problema", "profesor",
        "préstamo", "pude", "pueblo", "puede", "pueden", "puedo", "puerta", "pues", "puesto", "puso", "que",
        "queda", "quedamos", "quedan", "quedar", "quedó", "querer", "quería", "queso", "quien", "quiere",
        "quiero", "quién", "qué", "recibo", "regar", "respuesta", "restaurante", "resto", "reunión", "ruta",
        "rápido", "sabe", "saber", "sal", "sale", "salir", "salió", "salsa", "se", "seguir", "según",
        "semana", "semanas", "sentir", "ser", "si", "sido", "siempre", "sigue", "silla", "sin", "sobre",
        "sol", "solo", "somos", "son", "sopa", "soy", "su", "supe", "sus", "sé", "sí", "sólo", "también",
        "tampoco", "tan", "tanto", "tarde", "tarjeta", "tarta", "te", "teléfono", "temprano", "tenemos",
        "tener", "tengo", "tenía", "terminar", "termine", "terminó", "tiempo", "tienda", "tiene", "tienen",
        "tienes", "toda", "todas", "todavía", "todo", "todos", "toma", "tomar", "tomara", "tomate", "tomo",
        "trabaja", "trabajar", "trabajo", "tren", "tráfico", "tu", "tus", "tuve", "té", "tú", "u", "un",
        "una", "unas", "universidad", "unos", "usted", "ustedes", "va", "vacaciones", "vacunas", "vacío",
        "vale", "vamos", "van", "vas", "ve", "veces", "vecino", "vecinos", "venir", "ventana", "veo", "ver",
        "veterinario", "vez", "vi", "viaje", "viejo", "viene", "vino", "viste", "visto", "vive", "vivir",
        "volver", "volvió", "vosotros", "voy", "vuelve", "y", "ya", "yo", "zapatos", "árbol", "árboles",
        "él", "última", "último"
    ]
}

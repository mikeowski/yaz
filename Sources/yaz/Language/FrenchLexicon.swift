import Foundation

/// High-frequency French words: the term-repair veto for French.
///
/// French needed it most: with no list, 10 of 30 everyday sentences changed
/// ("cours" and "courses" became Cursor, "docteur" Docker, "rideaux" Redis,
/// "déplacée" deploy, "sont" Sentry). With it, none of the 30 and none of
/// 20 held out change. Elided words count by what follows the apostrophe:
/// "l'école", "d'électricité".
enum FrenchLexicon {

    static let protectedWordThreshold: Double = 0.90

    private static let elisions = ["l'", "d'", "j'", "qu'", "n'", "s'", "c'", "m'", "t'"]

    static func isCommon(_ word: String) -> Bool {
        var folded = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"()«»"))
        guard !folded.isEmpty else { return false }
        for prefix in elisions where folded.hasPrefix(prefix) && folded.count > prefix.count {
            folded = String(folded.dropFirst(prefix.count))
            break
        }
        if common.contains(folded) { return true }
        for suffix in ["s", "x", "e", "es", "ée", "ées", "és"] where folded.count > suffix.count + 2 {
            if folded.hasSuffix(suffix), common.contains(String(folded.dropLast(suffix.count))) { return true }
        }
        return false
    }

    private static let common: Set<String> = [
        "a", "abandonner", "abandonné", "ai", "aime", "aimer", "aimé", "ajouter", "ajouté", "allait",
        "aller", "allez", "allons", "allé", "alors", "ami", "amie", "amis", "an", "annuler", "annulé",
        "année", "années", "ans", "appeler", "appelle", "appelé", "après", "arbre", "arbres", "argent",
        "arrive", "arriver", "arrivé", "arroser", "as", "attend", "attendre", "attends", "au",
        "aujourd'hui", "aussi", "autre", "autres", "aux", "avaient", "avait", "avant", "avec", "avez",
        "avion", "avoir", "avons", "aéroport", "balcon", "banque", "bas", "bateau", "batterie", "beaucoup",
        "beurre", "bien", "bon", "bonjour", "bonne", "bruit", "bureau", "bus", "c", "café", "campagne",
        "car", "carte", "ce", "cela", "celle", "celui", "ces", "cet", "cette", "ceux", "chaise", "chaque",
        "chargeur", "chat", "chaussures", "chef", "chemin", "chemise", "cher", "cheveux", "chez", "chien",
        "chose", "chère", "cinéma", "circulation", "clavier", "clés", "colis", "commander", "comme",
        "comment", "content", "couper", "coupé", "cour", "courir", "cours", "course", "courses", "court",
        "courte", "cuisine", "curseur", "d", "dans", "de", "dehors", "demain", "demander", "demandé",
        "depuis", "dernier", "dernière", "des", "devenir", "devenu", "devoir", "devoirs", "devons",
        "difficile", "dire", "dis", "disait", "disputer", "dit", "docker", "docteur", "dois", "doit",
        "doivent", "donc", "donne", "donner", "donné", "dont", "du", "dur", "dure", "décharger", "déchargé",
        "déjeuner", "déjà", "déplacer", "déplacé", "dîner", "dû", "eau", "elle", "elles", "emmener",
        "emmené", "en", "encore", "enfant", "enfants", "enfin", "ensuite", "entre", "entrer", "envoyer",
        "es", "est", "et", "eu", "examen", "facile", "facture", "faire", "fais", "faisait", "faisons",
        "fait", "famille", "fatigué", "femme", "fenêtre", "fermé", "fermée", "fille", "fils", "fin", "fini",
        "finir", "fleur", "fleurs", "fois", "font", "fromage", "fruit", "frère", "fut", "gare", "grand",
        "grand-mère", "grand-père", "grande", "grands-parents", "gâteau", "habite", "habiter", "haut",
        "heure", "heures", "hier", "homme", "hôtel", "ici", "idée", "il", "ils", "imprimante", "inscrire",
        "inscrit", "j", "jamais", "jardin", "je", "jeune", "jolie", "joue", "jouent", "jouer", "jour",
        "jours", "l", "la", "laisser", "laissé", "lait", "laver", "lavé", "le", "lent", "lente", "les",
        "lettre", "leur", "leurs", "lever", "levé", "libre", "ligne", "lignes", "liste", "lit", "livre",
        "livres", "livreur", "long", "loyer", "lui", "là", "m", "ma", "magasin", "mais", "maison", "mal",
        "malade", "manger", "mangé", "marché", "marquer", "marqué", "match", "matin", "mauvais", "me",
        "meilleur", "merci", "mes", "message", "met", "mets", "mettre", "mi-chemin", "midi", "minute",
        "minutes", "mis", "moi", "moins", "mois", "moment", "mon", "mère", "médecin", "médicaments", "même",
        "n", "ne", "nettoyer", "ni", "non", "nos", "notre", "nous", "nouveau", "nouveaux", "nouvelle",
        "nouvelles", "nuit", "occupé", "on", "ont", "or", "ordinateur", "ou", "oublie", "oublier", "oublié",
        "oui", "ouvert", "ouverte", "où", "pain", "panne", "papier", "par", "parapluie", "parcours",
        "parents", "parfois", "parle", "parler", "parlé", "pars", "part", "parti", "partie", "partir",
        "pas", "passe", "passer", "passé", "payer", "pays", "payé", "pendant", "pense", "penser", "pensé",
        "petit", "petit-déjeuner", "petite", "peu", "peut", "peut-être", "peuvent", "peux", "pharmacie",
        "pire", "pièce", "plante", "plantes", "plaît", "plein", "pleut", "pleuvoir", "pluie", "plus",
        "poisson", "port", "porte", "poste", "pour", "pourquoi", "pouvoir", "pouvons", "premier",
        "première", "prend", "prendre", "prends", "presque", "pris", "prix", "problème", "professeur",
        "préparer", "préparé", "prêt", "prêter", "prêterai", "pu", "puis", "pâtes", "père", "qu", "quand",
        "que", "quel", "quelle", "quelles", "quelque", "quelques", "quels", "question", "qui", "quoi",
        "rapide", "ravis", "rentrer", "repasser", "restaurant", "reste", "rester", "resté", "retard",
        "reçu", "rideaux", "rien", "riz", "rue", "réconcilier", "réponse", "réunion", "réussi", "réussir",
        "rôle", "s", "s'il", "sa", "sais", "sait", "salle", "salut", "sans", "sauce", "savoir", "se", "sel",
        "semaine", "semaines", "serrées", "ses", "si", "soir", "soleil", "sommes", "son", "sont", "sors",
        "sort", "sorti", "sortir", "soupe", "souris", "sous", "souvent", "su", "sucre", "suis", "sur",
        "sœur", "t", "ta", "table", "tailler", "tard", "te", "temps", "tes", "thé", "toi", "tomate", "ton",
        "toujours", "tous", "tout", "toute", "toutes", "train", "travail", "trop", "trouve", "trouver",
        "trouvé", "très", "tu", "téléphone", "tôt", "un", "une", "université", "va", "vacances", "vaccins",
        "vais", "vas", "venir", "venu", "vers", "veut", "veux", "viande", "vide", "viens", "vient", "vieux",
        "village", "ville", "vin", "vite", "voir", "vois", "voisin", "voisins", "voit", "voiture", "vont",
        "vos", "votre", "vouloir", "voulu", "vous", "voyage", "vraiment", "vu", "vélo", "vétérinaire",
        "week-end", "y", "à", "ça", "école", "écran", "écrire", "écrit", "électricité", "étaient", "était",
        "été", "êtes", "être", "œuf"
    ]
}

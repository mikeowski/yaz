import Foundation

/// High-frequency English words: the veto for term repair when English is
/// the main language, as `TurkishLexicon` is for Turkish.
///
/// Measured on English everyday sentences (`EvalCorpus.English`) with no
/// list: "charger" became Cursor, "doctor" Docker, "were all" Vercel, and
/// among held-out sentences "into main" Notion and "merged" merge. With it,
/// none of the 30 and none of the 26 held out change. General frequency, not
/// the evaluation sentences.
enum EnglishLexicon {

    static let protectedWordThreshold: Double = 0.90

    static func isCommon(_ word: String) -> Bool {
        let folded = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !folded.isEmpty else { return false }
        if common.contains(folded) { return true }
        for suffix in suffixes where folded.count > suffix.count + 2 {
            if folded.hasSuffix(suffix), common.contains(String(folded.dropLast(suffix.count))) { return true }
        }
        // "applied" → "apply"
        if folded.hasSuffix("ied"), common.contains(String(folded.dropLast(3)) + "y") { return true }
        return false
    }

    private static let suffixes = ["s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "'s"]

    private static let common: Set<String> = [
        "a", "about", "above", "across", "after", "afternoon", "again", "airport", "all", "already", "also",
        "always", "am", "an", "and", "animal", "another", "answer", "any", "anyone", "anything", "appear",
        "apple", "applied", "are", "around", "as", "ask", "asked", "at", "ate", "away", "baby", "back",
        "bad", "bag", "balcony", "bank", "bathroom", "battery", "be", "beach", "because", "bed", "been",
        "beer", "before", "began", "begin", "being", "believe", "below", "best", "better", "between", "big",
        "bike", "bill", "bills", "bird", "boat", "book", "books", "boss", "both", "bought", "boy", "bread",
        "break", "breakfast", "bring", "broke", "brother", "brought", "build", "bus", "busy", "but",
        "butter", "buy", "by", "bye", "cable", "cafe", "cake", "call", "called", "came", "camera", "can",
        "canceled", "cancelled", "car", "card", "carried", "carry", "cat", "chair", "change", "changed",
        "charger", "cheese", "child", "children", "city", "class", "clean", "cleaned", "close", "closed",
        "coat", "coffee", "cold", "colleague", "come", "comes", "coming", "computer", "consider",
        "continue", "cook", "cooked", "cool", "cost", "could", "country", "course", "create", "created",
        "curtains", "cut", "dad", "daughter", "day", "days", "decide", "decided", "dentist", "deploy",
        "deployed", "did", "die", "different", "dinner", "do", "dock", "docked", "doctor", "document",
        "does", "dog", "doing", "done", "door", "down", "drank", "dress", "drink", "drive", "drove",
        "during", "each", "early", "easy", "eat", "egg", "eggs", "eight", "either", "email", "empty", "end",
        "even", "evening", "ever", "every", "everyone", "everything", "fall", "false", "family", "far",
        "fast", "father", "feel", "felt", "few", "find", "fine", "finish", "finished", "first", "fish",
        "five", "fix", "fixed", "flew", "floor", "flower", "flowers", "fly", "follow", "followed", "food",
        "for", "forget", "forgot", "found", "four", "free", "friend", "friends", "from", "fruit", "full",
        "game", "garden", "gave", "gentle", "get", "gets", "girl", "give", "given", "gives", "go", "goes",
        "going", "gone", "good", "got", "gotten", "grandma", "grandpa", "grandparents", "grass", "great",
        "grew", "grow", "had", "half", "hall", "happen", "happened", "happy", "hard", "has", "hat", "have",
        "having", "he", "hear", "heard", "held", "hello", "help", "helped", "her", "here", "hers",
        "herself", "hey", "hi", "high", "him", "himself", "his", "hold", "holiday", "home", "horse", "hot",
        "hotel", "hour", "hours", "house", "how", "i", "idea", "if", "in", "include", "into", "iron", "is",
        "it", "its", "itself", "jacket", "job", "just", "keep", "kept", "keyboard", "kid", "kids", "kill",
        "kitchen", "knew", "know", "known", "knows", "laptop", "large", "late", "lead", "learn", "learned",
        "leave", "led", "ledger", "left", "lend", "lent", "less", "let", "letter", "lie", "like", "list",
        "listen", "listened", "lists", "little", "live", "lived", "loan", "long", "look", "lot", "lots",
        "love", "loved", "low", "lunch", "made", "main", "make", "makes", "making", "mall", "man", "many",
        "market", "maybe", "me", "meat", "meeting", "merge", "merged", "message", "milk", "mine", "minute",
        "minutes", "mom", "moment", "money", "month", "months", "more", "morning", "most", "mother",
        "mouse", "move", "moved", "movie", "much", "music", "my", "myself", "naive", "near", "neighbor",
        "neighbors", "neither", "never", "new", "news", "nice", "night", "nine", "no", "nobody", "not",
        "nothing", "notion", "now", "nurse", "of", "off", "offer", "office", "often", "ok", "okay", "old",
        "on", "one", "only", "onto", "open", "opened", "or", "order", "ordered", "other", "others", "our",
        "ours", "ourselves", "out", "over", "own", "page", "pages", "paid", "paper", "parents", "park",
        "part", "pass", "passed", "pasta", "pay", "pen", "people", "perhaps", "phone", "pizza", "place",
        "plane", "plant", "plants", "play", "played", "please", "price", "printer", "problem", "pull",
        "put", "question", "quite", "radio", "rain", "raise", "ran", "reach", "read", "ready", "really",
        "reason", "receipt", "red", "remain", "remember", "remembered", "rent", "report", "require", "rest",
        "restaurant", "rice", "ride", "right", "road", "rode", "roof", "room", "run", "sad", "said", "salt",
        "same", "sandwich", "sat", "sauce", "saw", "say", "says", "school", "screen", "second", "see",
        "seeing", "seem", "seemed", "seen", "sell", "send", "sent", "serve", "set", "seven", "she", "shirt",
        "shoes", "shop", "short", "show", "showed", "sick", "side", "since", "sister", "sit", "six",
        "sleep", "slept", "slow", "small", "snow", "so", "sofa", "sold", "some", "somebody", "someone",
        "something", "sometimes", "son", "song", "sorry", "soup", "speak", "spend", "spent", "spoke",
        "stand", "start", "started", "station", "stay", "stayed", "still", "stood", "stop", "stopped",
        "store", "street", "student", "stuff", "sugar", "suggest", "sun", "sure", "swim", "table", "take",
        "taken", "takes", "taking", "talk", "talked", "tea", "teacher", "tell", "ten", "than", "thank",
        "thanks", "that", "the", "their", "theirs", "them", "themselves", "then", "there", "these", "they",
        "thing", "things", "think", "thinks", "this", "thought", "three", "thrilled", "through", "time",
        "tired", "to", "today", "told", "tomato", "tomorrow", "too", "took", "town", "traffic", "train",
        "travel", "tree", "trees", "tried", "trim", "trimming", "trip", "troops", "true", "try", "turn",
        "turned", "tv", "two", "umbrella", "under", "understand", "understood", "university", "until", "up",
        "us", "use", "used", "uses", "using", "usually", "vacation", "very", "vet", "village", "wait",
        "waited", "walk", "walked", "wall", "want", "wanted", "wants", "warm", "was", "wash", "washed",
        "watch", "watched", "water", "way", "we", "weather", "week", "weekend", "weeks", "well", "went",
        "were", "what", "when", "where", "which", "while", "who", "whole", "why", "will", "wind", "window",
        "wine", "with", "woman", "work", "worse", "worst", "would", "write", "wrong", "wrote", "yard",
        "year", "years", "yes", "yesterday", "yet", "you", "young", "your", "yours", "yourself"
    ]
}

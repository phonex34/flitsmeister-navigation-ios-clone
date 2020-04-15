
import AVFoundation
import MapboxCoreNavigation
import MapboxDirections
import MapboxSpeech

/**
 `SpeechSynthesizing` implementation, using `MapboxSpeech` framework. Uses pre-caching mechanism for upcoming instructions.
 */
open class MapboxSpeechSynthesizer: NSObject, SpeechSynthesizing {
    
    // MARK: - Properties
    
    public weak var delegate: SpeechSynthesizingDelegate?
    public var muted: Bool = false {
        didSet {
            updatePlayerVolume(audioPlayer)
        }
    }
    public var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }
    public var isSpeaking: Bool {
        return audioPlayer?.isPlaying ?? false
    }
    public var locale: Locale = Locale.autoupdatingCurrent
    
    public let stepsAheadToCache: Int = 3
    
    /**
     An `AVAudioPlayer` through which spoken instructions are played.
     */
    public var audioPlayer: AVAudioPlayer?
    
    private var cache: BimodalDataCache
    private var speech: SpeechSynthesizer
    private var audioTask: URLSessionDataTask?
    
    private var previousInstruction: SpokenInstruction?
    
    // MARK: - Lifecycle
    
    public init(_ accessToken: String? = nil, host: String? = nil) {
        self.cache = DataCache()
        self.speech = SpeechSynthesizer(accessToken: accessToken, host: host)
    }
    
    deinit {        
        deinitAudioPlayer()
    }
    
    // MARK: - Methods
    
    open func prepareIncomingSpokenInstructions(_ instructions: [SpokenInstruction]) {
        instructions
            .prefix(stepsAheadToCache)
            .forEach {
                if !hasCachedSpokenInstructionForKey($0.ssmlText, with: locale) {
                    downloadAndCacheSpokenInstruction(instruction: $0)
                }
        }
    }
    
    open func speak(_ instruction: SpokenInstruction, during legProgress: RouteLegProgress) {
        if let data = cachedDataForKey(instruction.ssmlText, with: locale) {
            safeDuckAudio(instruction: instruction)
            speak(instruction: instruction,
                  instructionData: data)
        }
        else {
            fetchAndSpeak(instruction: instruction)
        }
    }
    
    open func stopSpeaking() {
        audioPlayer?.stop()
    }
    
    open func interruptSpeaking() {
        audioPlayer?.stop()
    }
    
    // MARK: - Private Methods
    
    /**
     Fetches and plays an instruction.
     */
    private func fetchAndSpeak(instruction: SpokenInstruction){
        audioTask?.cancel()
        
        let modifiedInstruction = delegate?.speechSynthesizer(self, willSpeak: instruction) ?? instruction
        let ssmlText = modifiedInstruction.ssmlText
        let options = SpeechOptions(ssml: ssmlText)
        options.locale = locale
        
        audioTask = speech.audioData(with: options) { [weak self] (data, error) in
            guard let self = self else { return }
            if let speechError = error,
                case let .unknown(response: _, underlying: underlyingError, code: _, message: _) = speechError,
                let urlError = underlyingError as? URLError, urlError.code == .cancelled {
                self.delegate?.speechSynthesizer(self,
                                                 didSpeak: modifiedInstruction,
                                                 with: SpeechError.apiError(instruction: modifiedInstruction,
                                                                            options: options,
                                                                            underlying: urlError))
                return
            } else if let error = error {
                self.delegate?.speechSynthesizer(self,
                                                 didSpeak: modifiedInstruction,
                                                 with: SpeechError.apiError(instruction: modifiedInstruction,
                                                                            options: options,
                                                                            underlying: error))
                return
            }
            
            guard let data = data else {
                self.delegate?.speechSynthesizer(self,
                                                 didSpeak: modifiedInstruction,
                                                 with: SpeechError.noData(instruction: modifiedInstruction,
                                                                          options: options))
                return
            }
            
            self.cache(data, forKey: ssmlText, with: self.locale)
            self.safeDuckAudio(instruction: modifiedInstruction)
            self.speak(instruction: modifiedInstruction,
                       instructionData: data)
        }
        
        audioTask?.resume()
    }
    
    func speak(instruction: SpokenInstruction, instructionData: Data) {
        
        if let audioPlayer = audioPlayer {
            if let previousInstrcution = previousInstruction, audioPlayer.isPlaying{
                delegate?.speechSynthesizer(self,
                                            didInterrupt: previousInstrcution,
                                            with: instruction)
            }
            
            deinitAudioPlayer()
        }
        
        switch safeInitializeAudioPlayer(data: instructionData,
                                         instruction: instruction) {
        case .success(let player):
            audioPlayer = player
            previousInstruction = instruction
            audioPlayer?.play()
        case .failure(let error):
            safeUnduckAudio(instruction: instruction)
            delegate?.speechSynthesizer(self,
                                        didSpeak: instruction,
                                        with: error)
        }
    }
    
    private func downloadAndCacheSpokenInstruction(instruction: SpokenInstruction) {
        let modifiedInstruction = delegate?.speechSynthesizer(self, willSpeak: instruction) ?? instruction
        let ssmlText = modifiedInstruction.ssmlText
        let options = SpeechOptions(ssml: ssmlText)
        options.locale = locale
        
        speech.audioData(with: options) { [weak self] (data, error) in
            guard let data = data, let self = self else {
                return
            }
            self.cache(data, forKey: ssmlText, with: self.locale)
        }.resume()
    }
    
    func safeDuckAudio(instruction: SpokenInstruction?){
        if let error = AVAudioSession.sharedInstance().tryDuckAudio() {
            delegate?.speechSynthesizer(self,
                                        encounteredError: SpeechError.unableToControlAudio(instruction: instruction,
                                                                                           action: .duck,
                                                                                           underlying: error))
        }
    }
    
    func safeUnduckAudio(instruction: SpokenInstruction?) {
        if let error = AVAudioSession.sharedInstance().tryUnduckAudio() {
            delegate?.speechSynthesizer(self,
                                        encounteredError: SpeechError.unableToControlAudio(instruction: instruction,
                                                                                           action: .unduck,
                                                                                           underlying: error))
        }
    }
    
    private func cache(_ data: Data, forKey key: String, with locale: Locale) {
        cache.store(data, forKey: locale.identifier + key, toDisk: true, completion: nil)
    }
    private func cachedDataForKey(_ key: String, with locale: Locale) -> Data? {
        return cache.data(forKey: locale.identifier + key)
    }
    
    private func hasCachedSpokenInstructionForKey(_ key: String, with locale: Locale) -> Bool {
        return cachedDataForKey(key, with: locale) != nil
    }
    
    private func updatePlayerVolume(_ player: AVAudioPlayer?) {
        player?.volume = muted ? 0.0 : volume
    }
    
    private func safeInitializeAudioPlayer(data: Data, instruction: SpokenInstruction) -> Result<AVAudioPlayer, SpeechError> {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            updatePlayerVolume(player)
            
            return .success(player)
        } catch {
            return .failure(SpeechError.unableToInitializePlayer(playerType: AVAudioPlayer.self,
                                                                 instruction: instruction,
                                                                 synthesizer: speech,
                                                                 underlying: error))
        }
    }
    
    private func deinitAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
    }
}

extension MapboxSpeechSynthesizer: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        safeUnduckAudio(instruction: previousInstruction)
        
        guard let instruction = previousInstruction else {
            assert(false, "Speech Synthesizer finished speaking 'nil' instruction")
            return
        }
        
        delegate?.speechSynthesizer(self,
                                    didSpeak: instruction,
                                    with: nil)
    }
}
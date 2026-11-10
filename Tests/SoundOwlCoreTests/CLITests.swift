import ArgumentParser
import Testing
@testable import SoundOwlCLI
@testable import SoundOwlCore

struct CLITests {
    @Test func restoreIsTheDefaultCommand() throws {
        let command = try #require(try Root.parseAsRoot(["a.m4a", "b.wav"]) as? Restore)
        #expect(command.inputs == ["a.m4a", "b.wav"])
        #expect(command.denoise == nil)
        #expect(command.format == nil)
    }

    @Test func flagsOverrideTheDefaultRecipe() throws {
        let command = try #require(try Root.parseAsRoot(["restore", "a.m4a", "--no-denoise", "--format", "wav"]) as? Restore)
        #expect(command.denoise == false)
        #expect(command.format == .wav)
        let stored = Recipe.standard.overriding(denoise: true, format: .alac)
        let recipe = stored.overriding(denoise: command.denoise, format: command.format)
        #expect(recipe.denoise == false)
        #expect(recipe.format == .wav)
        // Left out, the stored settings win.
        let plain = try #require(try Root.parseAsRoot(["a.m4a"]) as? Restore)
        #expect(stored.overriding(denoise: plain.denoise, format: plain.format) == stored)
    }

    @Test func rejectsUnknownFormats() {
        #expect(throws: (any Error).self) { try Root.parseAsRoot(["a.m4a", "--format", "mp3"]) }
    }

    @Test func modelHasItsOwnCommands() throws {
        #expect(try Root.parseAsRoot(["model"]) is ModelCommand.Status)
        #expect(try Root.parseAsRoot(["model", "path"]) is ModelCommand.Path)
    }
}

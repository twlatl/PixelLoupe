import Foundation
import os
import Testing
@testable import PixelLoupe

@Suite("Person matte for Portrait Lighting (RAW-213)")
struct PersonMatteTests {
    private typealias Matte = SubjectMatteStore.Matte

    /// The left half white: a person on the left of the frame.
    private static let leftHalf = Matte(width: 4, height: 2, bytes: Data([255, 255, 0, 0, 255, 255, 0, 0]))

    /// A store in its own folder whose detectors count their calls: subjects are the whole frame, people `people`.
    private func store(people: Matte? = PersonMatteTests.leftHalf) throws
        -> (SubjectMatteStore, subjects: OSAllocatedUnfairLock<Int>, people: OSAllocatedUnfairLock<Int>, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let subjectCalls = OSAllocatedUnfairLock(initialState: 0), peopleCalls = OSAllocatedUnfairLock(initialState: 0)
        let store = SubjectMatteStore(directory: directory.url.appending(path: "Mattes"), detect: { _ in
            subjectCalls.withLock { $0 += 1 }
            return Matte(width: 4, height: 2, bytes: Data(repeating: 255, count: 8))
        }, detectPeople: { _ in
            peopleCalls.withLock { $0 += 1 }
            return people
        })
        return (store, subjectCalls, peopleCalls, directory)
    }

    private func source(in directory: TemporaryDirectory) throws -> DevelopSource {
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 300, height: 200)
        return try #require(DevelopSource(url: url))
    }

    @Test("People are found apart from the subject, under their own key, and kept on disk")
    func keptApartFromTheSubject() throws {
        let (store, subjects, people, directory) = try store()
        let source = try source(in: directory)
        let adjustments = PhotoAdjustments()
        let subjectKey = SubjectMatteStore.Request(source: source, adjustments: adjustments).key
        #expect(SubjectMatteStore.Request(source: source, adjustments: adjustments, kind: .person).key != subjectKey)

        #expect(store.status(for: source, adjustments: adjustments, kind: .person) == .finding)
        let person = try #require(store.matte(for: source, adjustments: adjustments, kind: .person, waiting: true))
        #expect(person.bytes == Self.leftHalf.bytes)
        #expect(store.status(for: source, adjustments: adjustments, kind: .person) == .found)
        #expect(store.status(for: source, adjustments: adjustments) == .finding, "the subject isn't found with people")
        #expect(people.withLock { $0 } == 1 && subjects.withLock { $0 } == 0)

        let subject = try #require(store.matte(for: source, adjustments: adjustments, waiting: true))
        #expect(subject.bytes != person.bytes)
        #expect(subjects.withLock { $0 } == 1 && people.withLock { $0 } == 1)

        // The next launch reads both from disk.
        let reread = SubjectMatteStore(directory: store.directory, detect: { _ in nil }, detectPeople: { _ in nil })
        #expect(reread.matte(for: source, adjustments: adjustments, kind: .person, waiting: true)?.bytes == person.bytes)
        #expect(reread.matte(for: source, adjustments: adjustments, waiting: true)?.bytes == subject.bytes)
    }

    @Test("The refined person matte is pulled from the people, not the subject")
    func refined() throws {
        let (store, subjects, people, directory) = try store()
        let source = try source(in: directory)
        let refined = try #require(store.refinedMatte(for: source, adjustments: PhotoAdjustments(), kind: .person, waiting: true))
        #expect(refined.width == 4 && refined.height == 2)
        #expect(refined.bytes[0] > refined.bytes[3], "still the left half: \(Array(refined.bytes))")
        #expect(store.status(for: source, adjustments: PhotoAdjustments(), kind: .person, refined: true) == .found)
        #expect(people.withLock { $0 } == 1 && subjects.withLock { $0 } == 0)
    }

    @Test("No person is remembered as no person")
    func noPerson() throws {
        let (store, _, people, directory) = try store(people: .noSubject)
        let source = try source(in: directory)
        #expect(store.matte(for: source, adjustments: PhotoAdjustments(), kind: .person, waiting: true)?.hasSubject == false)
        #expect(store.status(for: source, adjustments: PhotoAdjustments(), kind: .person) == .noSubject)
        _ = store.refinedMatte(for: source, adjustments: PhotoAdjustments(), kind: .person, waiting: true)
        #expect(store.status(for: source, adjustments: PhotoAdjustments(), kind: .person, refined: true) == .noSubject)
        #expect(people.withLock { $0 } == 1)
    }

    @Test("A mask with hardly anyone in it is no person")
    func hardlyAnyone() {
        var bytes = Data(repeating: 0, count: 100 * 100)
        #expect(!SubjectMatteStore.hasPerson(Matte(width: 100, height: 100, bytes: bytes)))
        bytes[0] = 255
        #expect(!SubjectMatteStore.hasPerson(Matte(width: 100, height: 100, bytes: bytes)), "one pixel in 10,000 is noise")
        for index in 0..<10 { bytes[index] = 200 }
        #expect(SubjectMatteStore.hasPerson(Matte(width: 100, height: 100, bytes: bytes)))
        #expect(!SubjectMatteStore.hasPerson(.noSubject))
    }

    @Test("Vision's mask is scaled to the image it was found in")
    func scaled() throws {
        let scaled = try #require(SubjectMatteStore.scaled(Self.leftHalf, width: 40, height: 20))
        #expect(scaled.width == 40 && scaled.height == 20 && scaled.bytes.count == 800)
        #expect(scaled.bytes[10 * 40 + 2] > 200 && scaled.bytes[10 * 40 + 37] < 50)
        #expect(SubjectMatteStore.scaled(.noSubject, width: 40, height: 20) == nil)
    }

}

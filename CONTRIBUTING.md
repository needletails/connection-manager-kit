# Contributing to ConnectionManagerKit

Thank you for your interest in contributing to ConnectionManagerKit! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## Code of Conduct

This project and everyone participating in it is governed by our Code of Conduct. By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

- Use the GitHub issue tracker
- Include detailed steps to reproduce the bug
- Provide system information (OS, Swift version, etc.)
- Include error messages and stack traces
- Describe the expected vs actual behavior

### Suggesting Enhancements

- Use the GitHub issue tracker with the "enhancement" label
- Clearly describe the proposed feature
- Explain why this enhancement would be useful
- Include use cases and examples

### Code Contributions

- Fork the repository
- Create a feature branch
- Make your changes
- Add tests for new functionality
- Update documentation
- Submit a pull request

## Development Setup

### Prerequisites

- Swift 6.0+
- Xcode 15.0+ (for Apple platforms)
- Linux development environment (for Linux support)

### Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/needletails/connection-manager-kit.git
   cd connection-manager-kit
   ```

2. Open in Xcode:
   ```bash
   open Package.swift
   ```

3. Build the project:
   ```bash
   swift build
   ```

4. Run tests:
   ```bash
   swift test
   ```

### Project Structure

```
connection-manager-kit/
├── Sources/
│   └── ConnectionManagerKit/
│       ├── Connection/           # Connection management
│       ├── Listener/            # Server-side listening
│       ├── Handlers/            # Network event monitoring
│       ├── Helpers/             # Models and protocols
│       └── Documentation.docc/  # Documentation
├── Tests/
│   └── ConnectionManagerKitTests/
└── Package.swift
```

## Coding Standards

### Swift Style Guide

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use Swift 6.0+ features where appropriate
- Prefer async/await over completion handlers
- Use meaningful variable and function names
- Add comprehensive documentation comments

### Code Formatting

- Use consistent indentation (4 spaces)
- Keep lines under 120 characters
- Add trailing commas for multi-line collections
- Use explicit type annotations when beneficial

### Architecture Principles

- Follow SOLID principles
- Use dependency injection
- Keep components loosely coupled
- Write testable code
- Document public APIs

## Testing

### Running Tests

```bash
# Run all tests
swift test

# Run specific test
swift test --filter ConnectionManagerTests

# Run tests with verbose output
swift test --verbose
```

### Writing Tests

- Write tests for all new functionality
- Use descriptive test names
- Test both success and failure cases
- Mock external dependencies
- Test edge cases and error conditions

### Test Structure

```swift
import XCTest
@testable import ConnectionManagerKit

final class ConnectionManagerTests: XCTestCase {
    
    func testConnectionEstablishment() async throws {
        // Arrange
        let manager = ConnectionManager()
        
        // Act
        try await manager.connect(to: servers)
        
        // Assert
        XCTAssertTrue(manager.isConnected)
    }
}
```

## Documentation

### Code Documentation

- Document all public APIs
- Use Swift DocC format
- Include usage examples
- Document parameters and return values
- Add `@available` annotations for platform-specific APIs

### Example Documentation

```swift
/// Manages network connections with automatic reconnection support.
///
/// The `ConnectionManager` provides a high-level interface for establishing
/// and maintaining network connections with built-in retry logic and
/// graceful error handling.
///
/// ## Usage
///
/// ```swift
/// let manager = ConnectionManager()
/// try await manager.connect(to: servers)
/// ```
///
/// - Note: This class is thread-safe and can be used from multiple threads.
/// - Important: Always call `gracefulShutdown()` before deallocating.
@available(iOS 17.0, macOS 14.0, *)
public class ConnectionManager {
    // Implementation...
}
```

### Building Documentation

```bash
# Generate documentation
swift package generate-documentation

# Build documentation for specific target
swift package generate-documentation --target ConnectionManagerKit
```

## Pull Request Process

### Before Submitting

1. Ensure all tests pass
2. Update documentation
3. Add tests for new functionality
4. Follow coding standards
5. Update CHANGELOG.md if needed

### Pull Request Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added/updated
```

### Review Process

1. Automated checks must pass
2. At least one maintainer must approve
3. All conversations must be resolved
4. Documentation must be updated
5. Tests must be comprehensive

## Release Process

### Versioning

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Release Checklist

- [ ] All tests pass
- [ ] Documentation is up to date
- [ ] CHANGELOG.md is updated
- [ ] Version is bumped in Package.swift
- [ ] Release notes are prepared
- [ ] Tag is created and pushed

### Creating a Release

1. Update version in `Package.swift`
2. Update `CHANGELOG.md`
3. Create and push tag:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
4. Create GitHub release with release notes

## Getting Help

- **Issues**: [GitHub Issues](https://github.com/needletails/connection-manager-kit/issues)
- **Discussions**: [GitHub Discussions](https://github.com/needletails/connection-manager-kit/discussions)
- **Documentation**: [Documentation.docc](Sources/ConnectionManagerKit/Documentation.docc)

## License

By contributing to ConnectionManagerKit, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to ConnectionManagerKit! 🚀 
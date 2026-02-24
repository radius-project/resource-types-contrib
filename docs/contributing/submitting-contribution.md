## Contribution Checklist

Before submitting your contribution. Make sure to check the following:

- [ ] File names follow naming conventions and folder structure
- [ ] Platform engineer documentation is in README.md
- [ ] Developer documentation is the top-level description property
- [ ] Example of defining the Resource Type is in the developer documentation
- [ ] Example of using the Resource Type with a Container is in the developer documentation
- [ ] Verified the output of `rad resource-type show` is correct
- [ ] All properties in the Resource Type definition have clear descriptions
- [ ] Enum properties have values defined in `enum: []`
- [ ] Required properties are listed in `required: []` for every object property (not just the top-level properties)
- [ ] Properties about the deployed resource, such as connection strings, are defined as read-only properties and are marked as `readOnly: true`
- [ ] Recipes include a results output variable with all read-only properties set
- [ ] Environment-specific parameters, such as a vnet ID, are exposed for platform engineers to set in the Environment
- [ ] Recipes use the [Recipe context object](https://docs.radapp.io/reference/context-schema/) when possible
- [ ] Recipes are provided for at least one platform
- [ ] Recipes handle secrets securely
- [ ] Recipes are idempotent
- [ ] Resource types and recipes were tested

## Submission Process

1. **Fork** this repository
2. **Create** a feature branch: `git checkout -b feature/my-resource-type`
3. **Add** your resource type definition and recipes
4. **Test** your resource type and recipe thoroughly
5. **Commit** your changes with description of the contribution
6. **Push** to your fork: `git push origin feature/my-resource-type`
7. **Create** a Pull Request with:
   - Clear description of the resource type
   - Usage examples
   - Testing instructions
   - Any special considerations

## Review Process

All contributions will be reviewed by the Radius maintainers and Approvers. The review will focus on:

- Contribution need and relevance 
- Schema correctness and consistency
- Recipe functionality and security
- Documentation completeness
- Test coverage as applicable

Thank you for contributing to the Radius ecosystem!
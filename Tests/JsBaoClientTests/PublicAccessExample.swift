import JsBaoClient

// Mark a database public so server functions may serve it to signed-out visitors (app owners and admins only).
func markPublic(client: JsBaoClient, db3Id: String) async throws -> Bool {
  // #region example
  let permissions = client.db3.permissions(db3Id)
  let change = try await permissions.setPublicAccess(.reader)
  if !change.signedOutAccess { print("Stored; it takes effect once the app's signedOutAccess is on") }
  try await permissions.setPublicAccess(nil) // clear it
  // #endregion example
  return change.changed
}

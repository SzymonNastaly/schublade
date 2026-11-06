import { createServerFn } from "@tanstack/react-start"
import { queryDocumentListing } from "../archive/document_listing"
import { database } from "../database/client"

export const listDocuments = createServerFn({ method: "GET" }).handler(() => queryDocumentListing(database))

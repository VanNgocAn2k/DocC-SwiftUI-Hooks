import SwiftUI
import Hooks
import IdentifiedCollections
import MCombineRequest

// MARK: Model

private struct Todo: Codable, Hashable, Identifiable {
  var id: UUID
  var text: String
  var isCompleted: Bool
}

private enum Filter: CaseIterable, Hashable {
  case all
  case completed
  case uncompleted
}

private struct Stats: Equatable {
  let total: Int
  let totalCompleted: Int
  let totalUncompleted: Int
  let percentCompleted: Double
}

// MARK: View

private typealias TodoContext = HookContext<Binding<IdentifiedArrayOf<Todo>>>

private struct TodoStats: View {
  
  var body: some View {
    HookScope {
      
      @HContext
      var context = TodoContext.self
      let todos = $context.value.wrappedValue
      let total = todos.count
      let totalCompleted = todos.filter(\.isCompleted).count
      let totalUncompleted = todos.filter { !$0.isCompleted }.count
      let percentCompleted = total <= 0 ? 0 : (Double(totalCompleted) / Double(total))
      let stats = Stats(
        total: total,
        totalCompleted: totalCompleted,
        totalUncompleted: totalUncompleted,
        percentCompleted: percentCompleted
      )
      VStack(alignment: .leading, spacing: 4) {
        stat("Total", "\(stats.total)")
        stat("Completed", "\(stats.totalCompleted)")
        stat("Uncompleted", "\(stats.totalUncompleted)")
        stat("Percent Completed", "\(Int(stats.percentCompleted * 100))%")
      }
      .padding(.vertical)
    }
  }
  
  private func stat(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title) + Text(":")
      Spacer()
      Text(value)
    }
  }
}

private struct TodoFilters: View {
  
  let filter: Binding<Filter>
  
  var body: some View {
    HookScope {
      Picker("Filter", selection: filter) {
        ForEach(Filter.allCases, id: \.self) { filter in
          switch filter {
            case .all:
              Text("All")
            case .completed:
              Text("Completed")
            case .uncompleted:
              Text("Uncompleted")
          }
        }
      }
      .padding(.vertical)
#if !os(watchOS)
      .pickerStyle(.segmented)
#endif
    }
  }
}

private struct TodoCreator: View {
  
  var body: some View {
    HookScope {
      
      @HContext
      var context = TodoContext.self
      let value = $context.value
      
      @HState
      var text = ""
      HStack {
        TextField("Enter your todo", text: $text)
#if os(iOS) || os(macOS)
          .textFieldStyle(.plain)
#endif
        Button {
          Task {
            let data = try await MRequest {
              RUrl("http://127.0.0.1:8080")
                .withPath("todos")
              Rbody(Todo(id: UUID(), text: text, isCompleted: false))
              RMethod(.post)
              REncoding(JSONEncoding.default)
            }
              .printCURLRequest()
              .data
            text = ""
            if let model = data.toModel(Todo.self) {
              value.wrappedValue.updateOrAppend(model)
            }
          }
        } label: {
          Text("Add")
            .bold()
            .foregroundColor(text.isEmpty ? .gray : .green)
        }
        .disabled(text.isEmpty)
      }
      .padding(.vertical)
    }
  }
}

private struct TodoItem: View {
  
  fileprivate let todoID: UUID
  
  fileprivate init(todoID: UUID) {
    self.todoID = todoID
  }
  
  var body: some View {
    HookScope {
      
      @HContext
      var context = TodoContext.self
      let todos = $context.value
      
      if let todo = todos.first(where: {$0.wrappedValue.id == self.todoID}) {
        Toggle(isOn: todo.map(\.isCompleted)) {
          TextField("", text: todo.map(\.text)) {
          }
          .textFieldStyle(.plain)
#if os(iOS) || os(macOS)
          .textFieldStyle(.roundedBorder)
#endif
        }
        .padding(.vertical, 4)
        .onChange(of: todo.wrappedValue) { (value: Todo) in
          Task {
            let data: Data = try await MRequest {
              RUrl("http://127.0.0.1:8080")
                .withPath("todos")
                .withPath(value.id.uuidString)
              Rbody(value)
              RMethod(.post)
              REncoding(JSONEncoding.default)
            }
              .printCURLRequest()
              .data
            if let model = data.toModel(Todo.self) {
              todos.wrappedValue.updateOrAppend(model)
            }
          }
        }
      }
    }
  }
}

struct TodoHookNetwork: View {
  
  @ViewBuilder
  var body: some View {
    HookScope {
      
      @HState
      var todos = IdentifiedArrayOf<Todo>()
      
      @HState
      var filter = Filter.all
      
      let flag : [AnyHashable] = [todos, filter]
      
      let filteredTodos = useMemo(.preserved(by: flag)) { () -> IdentifiedArrayOf<Todo> in
        switch filter {
          case .all:
            return todos
          case .completed:
            return todos.filter(\.isCompleted)
          case .uncompleted:
            return todos.filter { !$0.isCompleted }
        }
      }
      
      let (phase, refresher) = useAsyncPerform { () -> IdentifiedArrayOf<Todo> in
        let request = MRequest {
          RUrl("http://127.0.0.1:8080")
            .withPath("todos")
          RMethod(.get)
        }
        let data = try await request.data
        let models = try? JSONDecoder().decode(IdentifiedArrayOf<Todo>.self, from: data)
        return models ?? []
      }
      
      let _ = useLayoutEffect(.preserved(by: phase.status)) {
        switch phase {
          case .success(let items):
            todos = items
          default:
            break
        }
        return nil
      }
      
      TodoContext.Provider(value: $todos) {
        List {
          Section(header: Text("Information")) {
            TodoStats()
            TodoCreator()
          }
          Section(header: Text("Filters")) {
            TodoFilters(filter: $filter)
          }
          switch phase {
            case .success:
              ForEach(filteredTodos, id: \.id) { todo in
                TodoItem(todoID: todo.id)
              }
              .onDelete { atOffsets in
                for index in atOffsets {
                  let todo = todos[index]
                  Task {
                    let data: Data = try await MRequest {
                      RUrl("http://127.0.0.1:8080")
                        .withPath("todos")
                        .withPath(todo.id.uuidString)
                      RMethod(.delete)
                    }
                      .printCURLRequest()
                      .data
                    if let model = data.toModel(Todo.self) {
                      todos.remove(model)
                    }
                  }
                }
              }
              .onMove { fromOffsets, toOffset in
                // Move only in local
                todos.move(fromOffsets: fromOffsets, toOffset: toOffset)
              }
            case .failure(let error):
              Text(error.localizedDescription)
            default:
              ProgressView()
          }
        }
        .task {
          Task { @MainActor in
            await refresher()
          }
        }
        .refreshable {
          Task { @MainActor in
            await refresher()
          }
        }
        .listStyle(.sidebar)
        .toolbar {
          if filter == .all {
#if os(iOS)
            EditButton()
#endif
          }
        }
        .navigationTitle("Hook-Todos-" + filteredTodos.count.description)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
      }
    }
  }
}

#Preview {
  NavigationView { TodoHookNetwork() }
}

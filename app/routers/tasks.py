from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/v1/tasks", tags=["tasks"])


class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    done: bool = False


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    done: bool | None = None


class Task(BaseModel):
    id: int
    title: str
    done: bool


class TaskStore:
    """In-memory task storage. Not shared across multiple worker processes."""

    def __init__(self) -> None:
        self._tasks: dict[int, Task] = {}
        self._next_id = 1

    def list(self) -> list[Task]:
        return list(self._tasks.values())

    def create(self, data: TaskCreate) -> Task:
        task = Task(id=self._next_id, title=data.title, done=data.done)
        self._tasks[task.id] = task
        self._next_id += 1
        return task

    def get(self, task_id: int) -> Task:
        task = self._tasks.get(task_id)
        if task is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="task not found")
        return task

    def update(self, task_id: int, data: TaskUpdate) -> Task:
        task = self.get(task_id)
        updated = task.model_copy(update=data.model_dump(exclude_unset=True))
        self._tasks[task_id] = updated
        return updated

    def delete(self, task_id: int) -> None:
        self.get(task_id)
        del self._tasks[task_id]

    def reset(self) -> None:
        self._tasks.clear()
        self._next_id = 1


store = TaskStore()


def get_store() -> TaskStore:
    return store


@router.get("", response_model=list[Task])
def list_tasks() -> list[Task]:
    return store.list()


@router.post("", response_model=Task, status_code=status.HTTP_201_CREATED)
def create_task(data: TaskCreate) -> Task:
    return store.create(data)


@router.get("/{task_id}", response_model=Task)
def get_task(task_id: int) -> Task:
    return store.get(task_id)


@router.patch("/{task_id}", response_model=Task)
def update_task(task_id: int, data: TaskUpdate) -> Task:
    return store.update(task_id, data)


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: int) -> None:
    store.delete(task_id)
